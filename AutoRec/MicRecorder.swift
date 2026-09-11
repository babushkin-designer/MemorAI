import Foundation
import AVFoundation
import ObjCTry

/// Records microphone audio (what you say) into a separate .m4a file
/// using AVAudioEngine + AVAudioFile.
///
/// Robustness features:
/// - Listens to AVAudioEngineConfigurationChange (route changes kill the engine silently otherwise).
/// - Watchdog: if no audio buffer arrives for >10s while we expect to be recording, restart the engine.
/// - All lifecycle and error events go through the shared `log()` so they land in memorai.log.
///
/// THREADING. Two parties touch this object:
///   * the tap block, on Core Audio's real-time thread;
///   * start/stop, the pause switch, the watchdog and the config-change
///     handler, all on the main queue.
/// Every field both parties touch lives behind `lock` and is spelled with a
/// leading underscore, so an unguarded access is visible at the call site.
/// The engine itself (and its observer/timer) belongs to the main queue alone.
///
/// The tap NEVER tears anything down. It records what happened, releases the
/// lock and posts a single main-queue event; the main queue owns the engine
/// lifecycle and RecordingManager owns the session. Calling `stop()` from
/// inside the tap — which is what the write-error path used to do — reenters
/// the engine from its own callback, and `removeTap` waits for that callback
/// to return.
class MicRecorder {
    private struct RecordingSummary {
        let bufferCount: UInt64
        let segmentCount: Int
        let gapCount: Int
        let gapSeconds: Double
        let maxGapSeconds: Double
    }

    /// One continuous stretch of mic audio written in a single audio format.
    /// A mid-call input-device switch ends the current segment and opens the
    /// next; MicStitcher joins them back into `outputURL` when recording stops.
    struct Segment {
        let url: URL
        /// Host-clock seconds of this segment's first buffer — the stitcher
        /// derives the silence needed to bridge the engine restart from it.
        let firstBufferHostSeconds: Double?
        /// Frames written, or -1 for a part file picked up off disk after a
        /// crash — unknown length, which is not the same as no audio.
        let frameCount: AVAudioFramePosition
        let sampleRate: Double

        var duration: Double {
            sampleRate > 0 && frameCount > 0 ? Double(frameCount) / sampleRate : 0
        }
        var isEmpty: Bool { frameCount == 0 }

        /// A segment the recorder never got to close (the process was killed
        /// mid-call). Nothing is known about it beyond where it is, so the
        /// stitcher joins it without trying to bridge a gap.
        static func recovered(url: URL) -> Segment {
            Segment(url: url, firstBufferHostSeconds: nil, frameCount: -1, sampleRate: 0)
        }
    }

    private let outputURL: URL
    private let lock = UnfairLock()

    // MARK: - Main queue only (the engine and its supervision)

    private var engine: AVAudioEngine?
    private var watchdogTimer: Timer?
    private let watchdogInterval: TimeInterval = 5.0
    private let maxStallSeconds: TimeInterval = 10.0
    private var configChangeObserver: NSObjectProtocol?
    /// True between a config-change notification and the debounced engine
    /// restart it schedules.
    private var restartPending = false
    private let configChangeDebounce: TimeInterval = 0.5

    // MARK: - Shared state (lock)

    private var _audioFile: AVAudioFile?
    private var _isRecording = false
    private var _isPaused = false
    /// Closed segments in recording order. Populated as the recording goes and
    /// completed by `stop()`.
    private var _segments: [Segment] = []
    private var _currentSegmentIndex = 1
    private var _currentSegmentFirstHost: Double?
    private var _currentSegmentURL: URL
    private var _pausedAt: Date?
    /// Silence owed to the file for time spent paused, written on the next
    /// buffer. Not written when the recording stops while still paused — the
    /// system recorder's file ends at the pause too, so both tracks end
    /// together and adding silence there would be the drift, not the fix.
    private var _pendingSilenceSeconds: TimeInterval = 0
    /// Host-clock time (seconds, same clock as SCStream PTS) of the first
    /// recorded buffer — lets AudioMuxer align this track with system audio.
    private var _firstBufferHostSeconds: Double?
    private var _lastBufferTime: Date?
    private var _bufferCount: UInt64 = 0
    /// Where the next tap callback should start, from the last one's host time
    /// plus its own length. A callback that starts later than that is input the
    /// engine did not deliver — the mic-side twin of an output dropout, and the
    /// only cheap way to see one without logging from the audio thread.
    private var _expectedNextHost: Double?
    private var _tapGaps = 0
    private var _tapGapSeconds = 0.0
    private var _tapMaxGapSeconds = 0.0
    private var _writeErrorCount = 0
    /// Set once the tap has asked for recovery, so a tap that keeps failing
    /// posts exactly one event instead of one per buffer.
    private var _recoveryRequested = false
    private var _silenceStart: Date?
    private var _isSilent = false

    private let maxWriteErrors = 5

    // MARK: - Callbacks

    /// Fires on transitions: true = mic silent for silenceDurationThreshold, false = voice resumed.
    var onSilenceChanged: ((Bool) -> Void)?
    /// The mic is down and cannot be brought back. Fired once, on the main
    /// queue, after this recorder has finalized its own files. RecordingManager
    /// ends the session on it: leaving the manager in `.recording` with a dead
    /// mic kept the system track rolling into a session nobody would finish.
    var onFatalError: (() -> Void)?

    // MARK: - Accessors

    /// Closed segments, safe to read once `stop()` has returned.
    var segments: [Segment] { lock.withLock { _segments } }
    var firstBufferHostSeconds: Double? { lock.withLock { _firstBufferHostSeconds } }

    /// Pausing drops tap buffers, so paused wall-clock time is simply missing
    /// from the mic file. The system recorder does NOT compress the same way:
    /// it appends its buffers with their original PTS, so its writer keeps the
    /// gap in the timeline. Without putting that time back as silence the two
    /// tracks drift apart by the length of every pause — and the transcript
    /// interleaves them by timestamp.
    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set {
            lock.withLock {
                guard newValue != _isPaused else { return }
                _isPaused = newValue
                if newValue {
                    _pausedAt = Date()
                } else if let pausedAt = _pausedAt {
                    _pendingSilenceSeconds += Date().timeIntervalSince(pausedAt)
                    _pausedAt = nil
                }
            }
        }
    }

    init(outputURL: URL) {
        self.outputURL = outputURL
        self._currentSegmentURL = outputURL
    }

    /// ExtAudioFile refuses to encode AAC beyond 2 channels: a 6ch or 7ch
    /// buffer fails EVERY write with -66567 (verified directly against
    /// AVAudioFile), and virtual/aggregate input devices do present 7 channels.
    /// Such input is written as LPCM instead and normalized to AAC at the end.
    private static let maxAACChannels: AVAudioChannelCount = 2

    /// `call_<tag>_mic.part<N>.<ext>` — EVERY segment, including the first.
    /// The canonical `call_<tag>_mic.m4a` is published by MicStitcher, and only
    /// once it holds the whole track; while the first segment carried that name
    /// itself, a failed stitch left the opening minutes of a call passing for
    /// the whole of it, and AudioMuxer and Transcriber consumed it as such.
    ///
    /// CallHistory.parse reads the role after the last underscore, so these
    /// land as role "mic.partN" and are ignored by the Recent Calls menu.
    private func segmentURL(index: Int, aac: Bool) -> URL {
        outputURL.deletingPathExtension()
            .appendingPathExtension("part\(index)")
            .appendingPathExtension(aac ? outputURL.pathExtension : "caf")
    }

    // MARK: - Lifecycle (main queue)

    func start() throws {
        let alreadyRunning = lock.withLock { _isRecording }
        guard !alreadyRunning else { return }

        try? FileManager.default.removeItem(at: outputURL)

        try startEngine()
        lock.withLock { _isRecording = true }
        startWatchdog()

        log("[MicRecorder] Recording started → \(outputURL.lastPathComponent)")
    }

    func stop() {
        let wasRecording: Bool = lock.withLock {
            defer { _isRecording = false }
            return _isRecording
        }
        guard wasRecording else { return }

        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        // Outside the lock, and before touching the shared state: removeTap
        // waits for an in-flight tap callback to return, and that callback
        // wants the very lock we would be holding.
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        let summary = lock.withLock { () -> RecordingSummary in
            closeCurrentSegmentLocked()
            _silenceStart = nil
            _isSilent = false
            return RecordingSummary(
                bufferCount: _bufferCount,
                segmentCount: _segments.count,
                gapCount: _tapGaps,
                gapSeconds: _tapGapSeconds,
                maxGapSeconds: _tapMaxGapSeconds
            )
        }
        let extra = summary.segmentCount > 1 ? " in \(summary.segmentCount) segments" : ""
        log("[MicRecorder] Recording stopped (\(summary.bufferCount) buffers total\(extra))")
        if summary.gapCount > 0 {
            log(String(format: "[MicRecorder] Tap health — %d late callback(s), %.3fs unaccounted, max %.3fs",
                       summary.gapCount, summary.gapSeconds, summary.maxGapSeconds))
        }
    }

    /// AVFAudio raises ObjC exceptions on some device-transition failures
    /// instead of returning an error, and those abort the process rather than
    /// landing in a Swift `catch` — an AirPods switch mid-call killed the app
    /// this way. Routing the start through the shim turns such a raise into an
    /// ordinary error the caller can handle.
    private func startEngine() throws {
        var swiftError: Error?
        var raised: NSError?
        let completed = MEMRunCatchingExceptions({
            do { try self.openEngine() } catch { swiftError = error }
        }, &raised)
        if let swiftError = swiftError { throw swiftError }
        if !completed, let raised = raised {
            log("[MicRecorder] ⚠️ AVFAudio raised while starting the engine: \(raised.localizedDescription)")
            throw raised
        }
    }

    /// Captures the mic exactly as the device delivers it. No Apple voice
    /// processing: it reconfigures the shared input device for every other app
    /// on the machine and made real meetings sound bad to the far side. Echo
    /// is removed after the call instead, by EchoCanceller.
    private func openEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw MicRecorderError.noMicAvailable
        }

        // Match the file's encoding format to the input device's native rate and channel
        // count. The tap delivers buffers in the device's native format (24/48/96 kHz, mono
        // or stereo); writing them into a hardcoded 48 kHz mono AVAudioFile silently packed
        // samples at the wrong rate and produced 2× speed audio (1.4.0/1.4.1) or empty files
        // when manual AVAudioConverter conversion failed (1.4.2). Standard AAC accepts any
        // sample rate and channel count, so writing in native format is reliable.
        let nativeSampleRate = recordingFormat.sampleRate
        let nativeChannels = recordingFormat.channelCount

        // No tap is installed at this point (start() has none yet, every
        // restart removes the old one first), so the file swap below cannot
        // race a write — the lock states that invariant rather than assuming it.
        var notices: [String] = []
        try lock.withLock {
            // An engine restart can come up in a different format (device
            // switch). A file's format is fixed when it is opened, so the rest
            // of the call continues in a NEW segment and MicStitcher rejoins
            // them at the end. Writing the new format into the old file instead
            // failed on every buffer and killed the mic for the remainder of
            // the call (seen 2026-08-10: 16 kHz/2ch → 48 kHz/7ch on an AirPods
            // switch ended the mic track 50 s into a 40 min call).
            if let file = _audioFile,
               file.processingFormat.sampleRate != nativeSampleRate
                || file.processingFormat.channelCount != nativeChannels {
                _expectedNextHost = nil
                let oldFormat = "\(Int(file.processingFormat.sampleRate))Hz/\(file.processingFormat.channelCount)ch"
                let newFormat = "\(Int(nativeSampleRate))Hz/\(nativeChannels)ch"
                notices.append("[MicRecorder] Input format changed mid-recording"
                    + " (\(oldFormat) → \(newFormat)) — continuing in a new segment")
                rollToNextSegmentLocked()
            }

            if _audioFile == nil {
                let useAAC = nativeChannels <= Self.maxAACChannels
                _currentSegmentURL = segmentURL(index: _currentSegmentIndex, aac: useAAC)
                let fileSettings: [String: Any] = useAAC ? [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: nativeSampleRate,
                    AVNumberOfChannelsKey: nativeChannels,
                    AVEncoderBitRateKey: 32000 * Int(nativeChannels),
                ] : [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: nativeSampleRate,
                    AVNumberOfChannelsKey: nativeChannels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                ]
                if !useAAC {
                    notices.append("[MicRecorder] \(nativeChannels)ch input — beyond what AAC can encode,"
                        + " writing LPCM \(_currentSegmentURL.lastPathComponent) (converted at stop)")
                }
                _audioFile = try AVAudioFile(
                    forWriting: _currentSegmentURL,
                    settings: fileSettings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
        }
        for notice in notices { log(notice) }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, when in
            self?.handleTap(buffer, at: when)
        }

        try engine.start()
        self.engine = engine
        lock.withLock { _lastBufferTime = Date() }
        // Re-scoped on every start: each restart builds a new engine object,
        // and the observer is bound to a specific one.
        installConfigChangeObserver(for: engine)

        log("[MicRecorder] Engine started: \(Int(nativeSampleRate))Hz/\(nativeChannels)ch (native, no resampling)")
    }

    // MARK: - The tap (audio thread)

    /// What the tap asks the rest of the app to do once it has let go of the
    /// lock. Nothing here is done on the audio thread itself.
    private struct TapEffects {
        var messages: [String] = []
        var silenceChanged: Bool?
        var needsRecovery = false
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        var effects = TapEffects()
        lock.withLock {
            guard _isRecording, !_isPaused else { return }
            _lastBufferTime = Date()
            _bufferCount &+= 1
            if when.isHostTimeValid {
                let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
                let length = buffer.format.sampleRate > 0
                    ? Double(buffer.frameLength) / buffer.format.sampleRate
                    : 0
                if let expected = _expectedNextHost {
                    let gap = hostSeconds - expected
                    if gap > max(length, 0.005) {
                        _tapGaps += 1
                        _tapGapSeconds += gap
                        _tapMaxGapSeconds = max(_tapMaxGapSeconds, gap)
                    }
                }
                if length > 0 { _expectedNextHost = hostSeconds + length }
            }
            if _currentSegmentFirstHost == nil, when.isHostTimeValid {
                let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
                _currentSegmentFirstHost = hostSeconds
                // The overall start (first segment's) is what AudioMuxer aligns
                // the track by; later segments only matter to MicStitcher.
                if _firstBufferHostSeconds == nil {
                    _firstBufferHostSeconds = hostSeconds
                    effects.messages.append("[MicRecorder] First buffer at host time \(String(format: "%.3f", hostSeconds))s")
                }
            }

            do {
                writePendingPauseSilenceLocked(into: &effects)
                try _audioFile?.write(from: buffer)
                _writeErrorCount = 0
            } catch {
                _writeErrorCount += 1
                effects.messages.append("[MicRecorder] ❌ Write error (\(_writeErrorCount)/\(maxWriteErrors)): \(error.localizedDescription)")
                if _writeErrorCount >= maxWriteErrors, !_recoveryRequested {
                    _recoveryRequested = true
                    effects.needsRecovery = true
                }
            }
            updateSilenceStateLocked(buffer, into: &effects)
        }

        for message in effects.messages { log(message) }
        if let silent = effects.silenceChanged {
            DispatchQueue.main.async { [weak self] in self?.onSilenceChanged?(silent) }
        }
        if effects.needsRecovery {
            DispatchQueue.main.async { [weak self] in self?.recoverFromWriteFailures() }
        }
    }

    /// The write path has been failing for `maxWriteErrors` buffers in a row —
    /// the file and the incoming format have diverged (this is what an
    /// unannounced device change looks like). Roll to a fresh segment in the
    /// current format, which is the same repair a device switch gets. Only if
    /// even that fails is the mic really gone, and then the session ends.
    private func recoverFromWriteFailures() {
        guard lock.withLock({ _isRecording }) else { return }
        log("[MicRecorder] ⚠️ \(maxWriteErrors) write errors in a row — rolling to a fresh segment")
        if restartEngine() {
            lock.withLock {
                _writeErrorCount = 0
                _recoveryRequested = false
            }
            return
        }
        log("[MicRecorder] ❌ Mic cannot be restarted — ending the session")
        stop()
        onFatalError?()
    }

    // MARK: - Engine supervision (main queue)

    private func installConfigChangeObserver(for engine: AVAudioEngine) {
        if let previous = configChangeObserver {
            NotificationCenter.default.removeObserver(previous)
            configChangeObserver = nil
        }
        // DEADLOCK HAZARD — do not tear the engine down inside this callback.
        // AVAudioEngine posts this notification from its own internal serial
        // queue and BLOCKS that queue (NSOperation waitUntilFinished) until
        // every observer returns. `engine = nil` in the callback runs
        // -[AVAudioEngine dealloc], which dispatch_syncs onto that very queue
        // → circular wait. With `queue: .main` that hangs the MAIN thread, so
        // the whole menu bar UI freezes and Stop Recording stops responding
        // (seen 2026-08-10: 40 min frozen after an input device switch).
        // So: return immediately, restart in a later main-queue turn when the
        // engine queue has been released.
        // Scoped to OUR engine: DictationManager and CallDetector run their own
        // AVAudioEngines in this process, and a route change in one of those
        // must not tear down the call recording.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleConfigChangeRestart() }
        }
    }

    /// Collapses the burst of route-change notifications a single device
    /// switch emits (3 in 3 s when AirPods connect) into one engine restart.
    /// Main-queue only, so `restartPending` needs no locking. If a change is
    /// somehow missed, the watchdog still restarts a stalled engine.
    private func scheduleConfigChangeRestart() {
        guard lock.withLock({ _isRecording }), !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + configChangeDebounce) { [weak self] in
            guard let self = self else { return }
            self.restartPending = false
            guard self.lock.withLock({ self._isRecording }) else { return }
            log("[MicRecorder] ⚠️ AudioEngine config change (input device switch) — restarting engine")
            // A failed restart is not fatal here: the watchdog keeps retrying
            // for as long as no buffers arrive, which is what carries the mic
            // through a device that is briefly absent.
            _ = self.restartEngine()
        }
    }

    /// Tears the engine down and brings it back on a new segment. Returns
    /// false when the mic could not be reopened.
    @discardableResult
    private func restartEngine() -> Bool {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // End the segment on EVERY restart, not just when the format changed:
        // the engine is down for a second or two either way, and that hole is
        // what the stitcher bridges with silence. Continuing into the same file
        // would silently pull the rest of the call earlier than the system track.
        lock.withLock { rollToNextSegmentLocked() }
        do {
            try startEngine()
            return true
        } catch {
            log("[MicRecorder] ❌ Engine restart failed: \(error.localizedDescription)")
            return false
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkWatchdog() {
        // A restart is already queued — don't stack a second one on top of it.
        guard !restartPending else { return }
        let snapshot = lock.withLock { (_isRecording, _isPaused, _lastBufferTime, _bufferCount) }
        guard snapshot.0, !snapshot.1, let last = snapshot.2 else { return }
        let stalled = Date().timeIntervalSince(last)
        guard stalled > maxStallSeconds else { return }
        log("[MicRecorder] ⚠️ No buffers for \(Int(stalled))s (total \(snapshot.3) buffers) — restarting engine")
        restartEngine()
    }

    // MARK: - Segment bookkeeping (lock held)

    /// Closes the open file (AVAudioFile finalizes the m4a on release) and
    /// records it as a segment. A segment with no frames in it is dropped and
    /// its URL reused — that happens when the engine fails to come back up
    /// after a device switch, before any audio has been captured.
    private func closeCurrentSegmentLocked() {
        guard let file = _audioFile else { return }
        let frames = file.length
        let rate = file.processingFormat.sampleRate
        _audioFile = nil
        guard frames > 0 else {
            // Nothing landed in it — don't leave an empty part file behind for
            // the stitcher (or the next launch's recovery pass) to find.
            try? FileManager.default.removeItem(at: _currentSegmentURL)
            return
        }
        _segments.append(Segment(url: _currentSegmentURL,
                                 firstBufferHostSeconds: _currentSegmentFirstHost,
                                 frameCount: frames,
                                 sampleRate: rate))
    }

    /// Ends the current segment and points the recorder at the next one.
    private func rollToNextSegmentLocked() {
        let before = _segments.count
        closeCurrentSegmentLocked()
        guard _segments.count > before else { return }   // nothing was written yet
        _currentSegmentIndex += 1
        _currentSegmentFirstHost = nil
        // _currentSegmentURL is assigned when the next file is opened — only
        // then is its channel count, and therefore its extension, known.
    }

    /// Writes out the silence owed for time spent paused, so the mic file keeps
    /// the same wall-clock length as the system track.
    private func writePendingPauseSilenceLocked(into effects: inout TapEffects) {
        guard _pendingSilenceSeconds > 0.05, let file = _audioFile else { return }
        let seconds = _pendingSilenceSeconds
        _pendingSilenceSeconds = 0
        let format = file.processingFormat
        // Written in chunks: a long pause would otherwise ask for one buffer of
        // hundreds of MB. The full duration always goes in — capping it would
        // silently shorten the mic timeline, which is the exact drift this
        // padding exists to prevent. Encoded silence costs almost nothing.
        let chunkFrames = AVAudioFrameCount(format.sampleRate)   // 1 s
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        do {
            while remaining > 0 {
                let frames = min(remaining, chunkFrames)
                chunk.frameLength = frames   // a fresh buffer is already zeroed
                try file.write(from: chunk)
                remaining -= frames
            }
            effects.messages.append(String(format: "[MicRecorder] Wrote %.1fs of silence for the paused stretch", seconds))
        } catch {
            effects.messages.append("[MicRecorder] ⚠️ Could not pad the pause: \(error.localizedDescription)")
        }
    }

    // MARK: - Silence detection

    /// RMS across all channels of a Float32 PCM buffer. Returns 0 for non-float formats.
    private func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for ch in 0..<channels {
            let samples = channelData[ch]
            for i in 0..<frameCount {
                let s = samples[i]
                sum += s * s
            }
        }
        return sqrtf(sum / Float(frameCount * channels))
    }

    private func updateSilenceStateLocked(_ buffer: AVAudioPCMBuffer, into effects: inout TapEffects) {
        let rms = bufferRMS(buffer)
        let now = Date()
        if rms < Self.silenceRMSThreshold {
            if _silenceStart == nil {
                _silenceStart = now
            }
            if !_isSilent, let start = _silenceStart,
               now.timeIntervalSince(start) >= Self.silenceDurationThreshold {
                _isSilent = true
                effects.messages.append("[MicRecorder] Silence detected (>\(Int(Self.silenceDurationThreshold))s)")
                effects.silenceChanged = true
            }
        } else {
            _silenceStart = nil
            if _isSilent {
                _isSilent = false
                effects.messages.append("[MicRecorder] Voice resumed")
                effects.silenceChanged = false
            }
        }
    }

    private static let silenceRMSThreshold: Float = 0.001
    private static let silenceDurationThreshold: TimeInterval = 90.0
}

enum MicRecorderError: Error, LocalizedError {
    case noMicAvailable

    var errorDescription: String? {
        switch self {
        case .noMicAvailable: return "No microphone available or format invalid"
        }
    }
}
