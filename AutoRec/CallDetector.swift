import Foundation
import CoreAudio
import AppKit
import Darwin

/// Detects active calls by watching which *other* processes hold the microphone input.
///
/// Uses the per-process CoreAudio API (macOS 14.2+): `kAudioHardwarePropertyProcessObjectList`
/// + `kAudioProcessPropertyIsRunningInput` + `kAudioProcessPropertyPID`. We filter out our
/// own PID, so our MicRecorder's AVAudioEngine does not mask call-end.
///
/// Call-end is primarily mic-release driven — a call app releases its own mic when the
/// meeting ends, while ambient room noise through our mic engine can keep RMS above
/// threshold indefinitely. One exception (see shouldStayInCall): while recording, a free
/// mic with ACTIVE system audio means the user muted themselves in the call app (Electron
/// apps release the mic on mute) — the call ends only once system audio goes silent too.
///
/// That exception is also what welds back-to-back meetings into one file: between two
/// calls the mic is free but the Mac is rarely silent, so the session runs on. Measured
/// 2026-09-01: one recording covered 07:12–11:38 UTC across five mic releases, ending only
/// when the speakers finally went quiet for 90 s — 4.4 hours and four meetings in a single
/// transcript. So the exception is now scoped to the app that was holding the mic: the far
/// side of YOUR call playing through Pachca keeps the recording, Spotify after it does
/// not. Same per-process API, `kAudioProcessPropertyIsRunningOutput`.
class CallDetector {
    var onCallStarted: (() -> Void)?
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// How many consecutive polls must agree before we change state.
    private let debounceCount = 2
    private var activeCount = 0
    private var inactiveCount = 0
    private var callActive = false

    private var recordingMode = false
    private var recordingStartTime: Date?

    /// Mic free and the app that was holding it silent for this long ends the
    /// recording, so the next call gets its own file. A starting point, not a
    /// measurement: the gap between two meetings is minutes, while a mute long
    /// enough to matter has the far side talking through it. Every release and
    /// re-acquisition is logged with its duration, so this can be tuned against
    /// real calls rather than argued about.
    ///
    /// The failure it can produce is a meeting split in two when nobody speaks
    /// for three minutes while the user is muted — two whole files, and
    /// recording resumes the moment the user unmutes.
    static let splitAfterCallAppQuiet: TimeInterval = 180

    /// PIDs seen holding the mic during this recording. "Is the call still on"
    /// is asked of these and nothing else.
    private var callAppPIDs: Set<pid_t> = []
    /// When the mic went free, and when the call apps last stopped playing.
    private var micFreeSince: Date?
    private var callAppQuietSince: Date?

    // Retained informational state (from RecordingManager callbacks). Not used for call-end.
    private(set) var systemAudioSilent = false
    private(set) var micSilent = false
    private(set) var systemAudioAvailable = true

    private let ourPID: pid_t = getpid()

    func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        timer?.tolerance = 0.5
        log("[CallDetector] Started monitoring (poll every \(pollInterval)s, our pid=\(ourPID))")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        log("[CallDetector] Stopped monitoring")
    }

    func enterRecordingMode() {
        recordingMode = true
        recordingStartTime = Date()
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        callAppPIDs = []
        micFreeSince = nil
        callAppQuietSince = nil
        log("[CallDetector] Entered recording mode")
    }

    func exitRecordingMode() {
        recordingMode = false
        recordingStartTime = nil
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        callAppPIDs = []
        micFreeSince = nil
        callAppQuietSince = nil
        activeCount = 0
        inactiveCount = 0
        callActive = false
        log("[CallDetector] Exited recording mode, resumed normal monitoring")
    }

    // MARK: - Informational callbacks (no-op for call-end, kept for logging / future use)

    func reportSystemAudioSilence(_ silent: Bool) {
        if systemAudioSilent != silent {
            systemAudioSilent = silent
            log("[CallDetector] System audio silence: \(silent)")
        }
    }

    func reportMicSilence(_ silent: Bool) {
        if micSilent != silent {
            micSilent = silent
            log("[CallDetector] Mic silence: \(silent)")
        }
    }

    func reportSystemAudioUnavailable() {
        guard systemAudioAvailable else { return }
        systemAudioAvailable = false
        log("[CallDetector] System audio unavailable (mic-only session)")
    }

    // MARK: - Poll

    private func checkStatus() {
        let foreign = foreignMicHolders()
        let inCall = !foreign.isEmpty

        if inCall {
            activeCount += 1
            inactiveCount = 0
        } else {
            inactiveCount += 1
            activeCount = 0
        }

        if recordingMode && inCall {
            callAppPIDs.formUnion(foreign.map { $0.pid })
            if let since = micFreeSince {
                // The instrument for the threshold above: how long the mic
                // actually sits free inside one meeting, versus between two.
                log("[CallDetector] Mic re-acquired after \(Int(Date().timeIntervalSince(since)))s free")
                micFreeSince = nil
                callAppQuietSince = nil
            }
        }

        if !callActive && activeCount >= debounceCount {
            callActive = true
            if !recordingMode {
                let who = foreign.map { $0.label }.joined(separator: ", ")
                log("[CallDetector] Mic captured by \(who) — call detected")
                onCallStarted?()
            }
            return
        }

        if callActive && inactiveCount >= debounceCount {
            // Muted-in-call-app case: Electron call apps (Pachca, Zoom web…)
            // fully release the mic while the user is muted, but the meeting
            // is still on — the far side keeps producing system audio. While
            // recording, treat "mic free but system audio active" as still
            // in-call; the call only ends once system audio has also been
            // silent for its threshold (or was never available).
            let now = Date()
            if recordingMode {
                if micFreeSince == nil { micFreeSince = now }
                if callAppsPlaying() {
                    callAppQuietSince = nil
                } else if callAppQuietSince == nil {
                    callAppQuietSince = now
                }
            }
            let quietFor = callAppQuietSince.map { now.timeIntervalSince($0) }

            if Self.shouldStayInCall(recordingMode: recordingMode,
                                     systemAudioAvailable: systemAudioAvailable,
                                     systemAudioSilent: systemAudioSilent,
                                     callAppQuietFor: quietFor,
                                     splitAfter: Self.splitAfterCallAppQuiet) {
                if inactiveCount == debounceCount {
                    let who = callAppQuietSince == nil ? "call app still playing" : "call app quiet"
                    log("[CallDetector] Mic released, \(who) — keeping recording")
                }
                return
            }
            callActive = false
            if recordingMode, let quietFor = quietFor, quietFor >= Self.splitAfterCallAppQuiet {
                log("[CallDetector] Mic free and the call app silent for \(Int(quietFor))s — ending here so the next call gets its own file")
            } else {
                log("[CallDetector] \(recordingMode ? "No other process holds mic" : "Mic released") — call ended")
            }
            onCallEnded?()
        }
    }

    /// Pure decision: mic is free, should we still consider the call active?
    ///
    /// Two ways to answer no. The Mac has gone quiet, so there is no call left
    /// to record — or something IS playing, but not the app that was holding
    /// the mic, and has not been for `splitAfter`. The second is music after a
    /// meeting rather than the far side of one.
    static func shouldStayInCall(recordingMode: Bool, systemAudioAvailable: Bool,
                                 systemAudioSilent: Bool,
                                 callAppQuietFor: TimeInterval? = nil,
                                 splitAfter: TimeInterval = .infinity) -> Bool {
        guard recordingMode, systemAudioAvailable, !systemAudioSilent else { return false }
        if let quiet = callAppQuietFor, quiet >= splitAfter { return false }
        return true
    }

    /// Is any app that held the mic during this recording playing audio? While
    /// the user is muted this is the far side talking, and the only thing that
    /// separates "still in the meeting" from "the meeting ended and iTunes
    /// picked up where it left off".
    private func callAppsPlaying() -> Bool {
        guard !callAppPIDs.isEmpty else { return false }
        for object in audioProcessObjects() {
            let pid = processPID(object)
            guard callAppPIDs.contains(pid) else { continue }
            if processIsRunningOutput(object) { return true }
        }
        return false
    }

    // MARK: - Per-process CoreAudio query

    private struct ForeignMicHolder {
        let pid: pid_t
        var label: String {
            if let app = NSRunningApplication(processIdentifier: pid),
               let name = app.localizedName ?? app.bundleIdentifier {
                return "\(name) (pid \(pid))"
            }
            return "pid \(pid)"
        }
    }

    /// Every process CoreAudio knows about, ours included. Callers filter.
    private func audioProcessObjects() -> [AudioObjectID] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects
        ) == noErr else {
            return []
        }
        return objects
    }

    /// Enumerates audio process objects and returns ones (other than us) capturing mic input.
    private func foreignMicHolders() -> [ForeignMicHolder] {
        var holders: [ForeignMicHolder] = []
        for obj in audioProcessObjects() {
            guard processIsRunningInput(obj) else { continue }
            let pid = processPID(obj)
            guard pid > 0, pid != ourPID else { continue }
            guard isUserFacingProcess(pid: pid) else { continue }
            holders.append(ForeignMicHolder(pid: pid))
        }
        return holders
    }

    /// System binaries that ARE calls despite living under /System or /usr/libexec:
    /// FaceTime routes the mic through the avconferenced daemon, not the app process.
    private static let callDaemonMarkers = [
        "avconferenced",     // FaceTime / SharePlay conference daemon
        "FaceTime.app",      // just in case the app ever holds the mic itself
        "callservicesd",     // continuity phone calls relayed to the Mac
    ]

    /// Returns false for system daemons (corespeechd, assistantd, coreaudiod, etc.) that
    /// hold the mic for background OS features like Siri / dictation and should never be
    /// treated as call activity. Anything shipping from /System or /usr/libexec qualifies —
    /// except the known call daemons above (FaceTime has no user-space mic holder at all).
    private func isUserFacingProcess(pid: pid_t) -> Bool {
        guard let path = executablePath(pid: pid) else { return false }
        if Self.isKnownCallDaemon(path) { return true }
        if path.hasPrefix("/System/") { return logFiltered(path) }
        if path.hasPrefix("/usr/libexec/") { return logFiltered(path) }
        if path.hasPrefix("/usr/sbin/") { return logFiltered(path) }
        if path.hasPrefix("/usr/bin/") { return logFiltered(path) }
        return true
    }

    static func isKnownCallDaemon(_ path: String) -> Bool {
        callDaemonMarkers.contains { path.contains($0) }
    }

    /// Diagnostics: log each distinct filtered mic-holder once per app run, so an
    /// undetected call app can be identified from memorai.log instead of guessed at.
    private var loggedFilteredPaths = Set<String>()
    private func logFiltered(_ path: String) -> Bool {
        if loggedFilteredPaths.insert(path).inserted {
            log("[CallDetector] Ignoring system mic holder: \(path)")
        }
        return false
    }

    private func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN, plenty for any real path
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let bytes = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard bytes > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processIsRunningOutput(_ object: AudioObjectID) -> Bool {
        processFlag(object, kAudioProcessPropertyIsRunningOutput)
    }

    private func processIsRunningInput(_ object: AudioObjectID) -> Bool {
        processFlag(object, kAudioProcessPropertyIsRunningInput)
    }

    private func processFlag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else {
            return 0
        }
        return pid
    }
}
