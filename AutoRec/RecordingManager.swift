import Foundation

/// Orchestrates system audio, mic, and screen recording.
@MainActor
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
    /// The on-disk record of the session in progress. Written before the
    /// recorders start, so even a session killed mid-call leaves something the
    /// next launch can finish.
    private var currentManifest: CallSessionManifest?
    private var currentBaseDir: URL?

    /// Owned by PostProcessor now — post-processing outlives a recording (and,
    /// across a manifest, the process itself).
    var isTranscribing: Bool { PostProcessor.shared.isTranscribing }

    init() {
        PostProcessor.shared.onTranscribingChanged = { [weak self] _ in
            guard let self = self else { return }
            self.onStateChange?(self.state)
        }
        PostProcessor.shared.onTranscriptionDone = { [weak self] in
            self?.onTranscriptionDone?()
        }
    }

    /// Finishes any session left half-processed by a previous run. Call once,
    /// at launch, after the callbacks above are wired.
    func resumeUnfinishedSessions() {
        PostProcessor.shared.resumePending(in: URL(fileURLWithPath: settings.outputPath))
    }

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
        self.currentBaseDir = baseDir

        var manifest = CallSessionManifest(tag: timestamp)
        manifest.micFile = micURL.lastPathComponent
        manifest.systemFile = sysURL.lastPathComponent
        manifest.screenFile = vidURL?.lastPathComponent
        manifest.save(in: baseDir)
        self.currentManifest = manifest

        // Instrumentation: count the IO deadlines the machine misses while we
        // record, and photograph the shared device parameters at every step, so
        // "the speakers crackle during a call" becomes a number attributable to
        // a specific stage instead of an impression.
        AudioGlitchMonitor.shared.start(context: "recording (\(source))")
        AudioGlitchMonitor.shared.snapshot("before recorders")

        // Close the gate BEFORE the recorders come up, and cancel whatever the
        // pipeline is already running: the call must not share the machine with
        // whisper or the AEC sidecar.
        PostProcessor.shared.setRecordingActive(true, dir: baseDir)

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
                AudioGlitchMonitor.shared.snapshot("after SCStream start")

                let micRec = MicRecorder(outputURL: micURL)
                micRec.onSilenceChanged = { [weak self] silent in
                    self?.onMicSilenceChanged?(silent)
                }
                // A dead mic ends the session, the same way an SCStream error
                // does. Keeping the manager in `.recording` around a stopped
                // recorder left the system track writing into a session that
                // nothing would ever finalize.
                micRec.onFatalError = { [weak self] in
                    guard let self = self, self.state == .recording || self.state == .starting else { return }
                    log("[RecordingManager] Mic recorder failed — stopping session")
                    self.stopRecording(source: "mic-error")
                }
                self.micRecorder = micRec
                try micRec.start()
                // If our second input client reconfigures the shared devices,
                // this snapshot differs from the one above — that is the whole
                // question, answered by measurement.
                AudioGlitchMonitor.shared.snapshot("after mic engine start")

                setState(.recording)
                log("[RecordingManager] All recorders running")
            } catch {
                log("[RecordingManager] ❌ Failed to start: \(error)")
                await systemAudioRecorder?.stop()
                micRecorder?.stop()
                systemAudioRecorder = nil
                micRecorder = nil
                // Nothing was recorded, so there is nothing to post-process.
                if let dir = currentBaseDir { currentManifest?.remove(in: dir) }
                currentManifest = nil
                PostProcessor.shared.setRecordingActive(false, dir: baseDir)
                AudioGlitchMonitor.shared.stop()
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
        let baseDir = currentBaseDir ?? URL(fileURLWithPath: settings.outputPath)

        Task {
            // Wait for a still-running startup to finish so we stop real, started
            // recorders — otherwise stop no-ops on nil/unstarted recorders and the
            // startup task then brings the session up with nobody left to stop it.
            await startTask?.value
            micRecorder?.stop()
            AudioGlitchMonitor.shared.snapshot("after mic engine stop")
            await systemAudioRecorder?.stop()
            AudioGlitchMonitor.shared.snapshot("after SCStream stop")
            AudioGlitchMonitor.shared.stop()
            // Recorders are down: the pipeline may have the machine back, and
            // anything deferred while the call ran gets picked up off disk.
            PostProcessor.shared.setRecordingActive(false, dir: baseDir)
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

            // No manifest means no session: a startup that failed removed its
            // own, and a synthesized replacement here would either enqueue the
            // partial files of a failed start as a finished call, or — worse —
            // stand in for a real session with none of its file names, which
            // would silently skip publishing the mic track. The completions
            // below still have to fire: on quit one of them is what lets the
            // process exit.
            guard var manifest = currentManifest else {
                log("[RecordingManager] Session never came up — nothing to post-process")
                drainStopCompletions(completion)
                return
            }

            // The timings above live only in the recorders; write them down
            // before anything else can go wrong, or a session interrupted
            // later can never be aligned again.
            manifest.micStartSeconds = micStart
            manifest.systemStartSeconds = sysStart
            manifest.videoStartSeconds = vidStart
            manifest.segments = micSegments.map(CallSessionManifest.record)
            manifest.recordingFinished = true

            // The mic is recorded into part files and becomes
            // call_<tag>_mic.m4a only once the whole track is there. A lone
            // segment in the output format is published by renaming it, which
            // is bounded work and safe to do before the completion below — on
            // app-quit that callback is what lets the process exit. Anything
            // needing ffmpeg is left to the pipeline, which resumes at the next
            // launch if this process does not live long enough to finish it.
            if micSegments.isEmpty {
                manifest.stages.micPublished = true      // the mic never produced audio
            } else if let micURL = micURL,
                      MicStitcher.shared.canPublishByRename(segments: micSegments, outputURL: micURL) {
                manifest.stages.micPublished =
                    MicStitcher.shared.stitch(segments: micSegments, outputURL: micURL)
            }
            manifest.save(in: baseDir)
            currentManifest = nil

            drainStopCompletions(completion)

            // Echo cancellation, muxing and transcription take minutes on a
            // long call — far longer than a quit may be held up. They run in
            // PostProcessor, off the manifest, and survive the app going away.
            PostProcessor.shared.enqueue(manifest, in: baseDir)
        }
    }

    /// Fires this stop's completion plus any that queued behind it. Every exit
    /// from the stop task must go through here — a dropped completion hangs
    /// `applicationShouldTerminate` until its failsafe fires.
    private func drainStopCompletions(_ completion: (() -> Void)?) {
        completion?()
        let queued = pendingStopCompletions
        pendingStopCompletions = []
        for pending in queued {
            DispatchQueue.main.async { pending() }
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
