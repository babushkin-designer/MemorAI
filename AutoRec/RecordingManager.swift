import Foundation

/// Orchestrates system audio, mic, and screen recording.
class RecordingManager {
    private(set) var state: RecordingState = .idle
    var onStateChange: ((RecordingState) -> Void)?
    var onRecordingActiveChanged: ((Bool) -> Void)?
    /// Fired when system audio silence state changes during recording.
    var onSilenceChanged: ((Bool) -> Void)?
    /// Fired when mic silence state changes during recording.
    var onMicSilenceChanged: ((Bool) -> Void)?
    /// Fired once if the session produced no system audio within the warmup window
    /// (mic-only voice memo or headphones-only call).
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fired when transcription completes after a recording
    var onTranscriptionDone: (() -> Void)?

    private var systemAudioRecorder: SystemAudioRecorder?
    private var micRecorder: MicRecorder?
    private let settings = SettingsManager.shared
    /// Completions queued when `stopRecording` is called again while a stop
    /// `Task` is already in flight (state == .stopping); drained once that
    /// in-flight task finishes finalizing the writers.
    private var pendingStopCompletions: [() -> Void] = []
    /// The in-flight startup task; stop must await it so a stop issued during
    /// .starting cannot run before the recorders exist (orphaned-session race).
    private var startTask: Task<Void, Never>?

    // Track current session file URLs for transcription
    private var currentMicURL: URL?
    private var currentSystemURL: URL?
    private var currentScreenURL: URL?

    private(set) var isTranscribing = false

    func startRecording(source: String = "manual") {
        guard state == .idle else {
            log("[RecordingManager] Cannot start — state is \(state)")
            return
        }
        log("[RecordingManager] Recording started (source: \(source))")
        setState(.starting)
        onRecordingActiveChanged?(true)

        settings.ensureOutputDirectory()

        let timestamp = Self.timestamp()
        let baseDir = URL(fileURLWithPath: settings.outputPath)

        let sysURL = baseDir.appendingPathComponent("call_\(timestamp)_system.m4a")
        let micURL = baseDir.appendingPathComponent("call_\(timestamp)_mic.m4a")
        let vidURL: URL? = settings.recordScreen
            ? baseDir.appendingPathComponent("call_\(timestamp)_screen.mp4")
            : nil

        self.currentMicURL = micURL
        self.currentSystemURL = sysURL
        self.currentScreenURL = vidURL

        startTask = Task {
            do {
                let sysRec = SystemAudioRecorder(audioURL: sysURL, videoURL: vidURL)
                // Wire up silence / availability / error signals
                sysRec.onSilenceChanged = { [weak self] silent in
                    self?.onSilenceChanged?(silent)
                }
                sysRec.onSystemAudioUnavailable = { [weak self] in
                    self?.onSystemAudioUnavailable?()
                }
                sysRec.onStreamError = { [weak self] error in
                    guard let self = self, self.state == .recording || self.state == .starting else { return }
                    log("[RecordingManager] SCStream error — stopping session: \(error.localizedDescription)")
                    self.stopRecording(source: "stream-error")
                }
                self.systemAudioRecorder = sysRec
                try await sysRec.start()

                let micRec = MicRecorder(outputURL: micURL)
                micRec.onSilenceChanged = { [weak self] silent in
                    self?.onMicSilenceChanged?(silent)
                }
                self.micRecorder = micRec
                try micRec.start()

                setState(.recording)
                log("[RecordingManager] All recorders running")
            } catch {
                log("[RecordingManager] ❌ Failed to start: \(error)")
                await systemAudioRecorder?.stop()
                micRecorder?.stop()
                systemAudioRecorder = nil
                micRecorder = nil
                setState(.idle)
                onRecordingActiveChanged?(false)
            }
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        systemAudioRecorder?.isPaused = true
        micRecorder?.isPaused = true
        setState(.paused)
        log("[RecordingManager] Paused")
    }

    func resumeRecording() {
        guard state == .paused else { return }
        systemAudioRecorder?.isPaused = false
        micRecorder?.isPaused = false
        setState(.recording)
        log("[RecordingManager] Resumed")
    }

    func stopRecording(source: String = "manual", completion: (() -> Void)? = nil) {
        guard state == .recording || state == .starting || state == .paused else {
            if state == .stopping {
                // A stop Task is already in flight; queue this completion so it
                // fires once that task finishes finalizing the writers, instead
                // of firing early (before finalization) or being dropped.
                if let completion = completion {
                    pendingStopCompletions.append(completion)
                }
            } else {
                completion?()
            }
            return
        }
        log("[RecordingManager] Recording stopped (source: \(source))")
        setState(.stopping)

        let micURL = currentMicURL
        let sysURL = currentSystemURL
        let screenURL = currentScreenURL

        Task {
            // Wait for a still-running startup to finish so we stop real, started
            // recorders — otherwise stop no-ops on nil/unstarted recorders and the
            // startup task then brings the session up with nobody left to stop it.
            await startTask?.value
            micRecorder?.stop()
            await systemAudioRecorder?.stop()
            // Track start times (host clock) — AudioMuxer aligns the three
            // files with these; grab them before the recorders are released.
            let micStart = micRecorder?.firstBufferHostSeconds
            let sysStart = systemAudioRecorder?.audioFirstPTSSeconds
            let vidStart = systemAudioRecorder?.videoFirstPTSSeconds
            // An input-device switch splits the mic track; rejoin it before
            // anything downstream reads micURL, so AudioMuxer and Transcriber
            // keep seeing a single file.
            let micSegments = micRecorder?.segments ?? []
            micRecorder = nil
            systemAudioRecorder = nil
            setState(.idle)
            onRecordingActiveChanged?(false)
            log("[RecordingManager] All recorders stopped")

            // Before the completion fires: on app-quit that callback is what
            // replies to applicationShouldTerminate, so anything left after it
            // races the process exit.
            // More than one segment (device switch), or a single segment that
            // isn't the final file yet (LPCM, written when the input had more
            // channels than AAC can encode).
            let needsStitch = micSegments.count > 1
                || (micSegments.first.map { $0.url != micURL } ?? false)
            if needsStitch, let micURL = micURL {
                MicStitcher.shared.stitch(segments: micSegments, outputURL: micURL)
            }

            completion?()
            let queued = pendingStopCompletions
            pendingStopCompletions = []
            for pending in queued {
                DispatchQueue.main.async { pending() }
            }

            // Strip the far side's speaker leak out of the mic track. Runs here,
            // after the UI is idle and the quit completion has fired, because a
            // long call takes minutes to process; the raw mic is left untouched
            // and used as-is if anything about the result looks wrong.
            var effectiveMicURL = micURL
            if let micURL = micURL, let sysURL = sysURL,
               EchoCanceller.shared.isAvailable {
                effectiveMicURL = EchoCanceller.shared.process(micURL: micURL, systemURL: sysURL) ?? micURL
            }

            // Mux mic + system audio into screen.mp4 in-place so the video file is
            // self-contained for downstream playback. Runs in parallel with transcription.
            if let screenURL = screenURL {
                AudioMuxer.shared.muxScreenWithAudio(screenURL: screenURL, micURL: effectiveMicURL, systemURL: sysURL,
                                                     micStartSeconds: micStart,
                                                     systemStartSeconds: sysStart,
                                                     videoStartSeconds: vidStart)
            }

            // Auto-transcribe if enabled and whisper is available
            if settings.autoTranscribe {
                guard Transcriber.shared.isAvailable else {
                    log("[RecordingManager] Auto-transcribe on but whisper/model missing — skipping")
                    return
                }
                isTranscribing = true
                onStateChange?(state) // trigger UI update
                log("[RecordingManager] Starting transcription…")
                // Transcribe the cleaned mic but keep naming the session after
                // the canonical file, or the transcript lands next to it under
                // a mangled name.
                Transcriber.shared.transcribeSession(micURL: effectiveMicURL, systemURL: sysURL,
                                                     namingURL: micURL) { [weak self] in
                    self?.isTranscribing = false
                    self?.onTranscriptionDone?()
                    self?.onStateChange?(self?.state ?? .idle)
                    log("[RecordingManager] Transcription complete")
                }
            }
        }
    }

    private func setState(_ newState: RecordingState) {
        state = newState
        onStateChange?(newState)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt.string(from: Date())
    }
}
