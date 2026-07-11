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
        log("[CallDetector] Entered recording mode")
    }

    func exitRecordingMode() {
        recordingMode = false
        recordingStartTime = nil
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
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
            if Self.shouldStayInCall(recordingMode: recordingMode,
                                     systemAudioAvailable: systemAudioAvailable,
                                     systemAudioSilent: systemAudioSilent) {
                if inactiveCount == debounceCount {
                    log("[CallDetector] Mic released but system audio still active (muted in call app?) — keeping recording")
                }
                return
            }
            callActive = false
            log("[CallDetector] \(recordingMode ? "No other process holds mic" : "Mic released") — call ended")
            onCallEnded?()
        }
    }

    /// Pure decision: mic is free, should we still consider the call active?
    static func shouldStayInCall(recordingMode: Bool, systemAudioAvailable: Bool,
                                 systemAudioSilent: Bool) -> Bool {
        recordingMode && systemAudioAvailable && !systemAudioSilent
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

    /// Enumerates audio process objects and returns ones (other than us) capturing mic input.
    private func foreignMicHolders() -> [ForeignMicHolder] {
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

        var holders: [ForeignMicHolder] = []
        for obj in objects {
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

    private func processIsRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
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
