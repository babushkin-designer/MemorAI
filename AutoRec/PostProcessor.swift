import Foundation

/// Everything that happens to a call after the recorders have stopped:
/// publish the mic track, cancel the echo in it, mux the audio into the video,
/// transcribe. Minutes of work on a long call.
///
/// It is driven off a manifest on disk rather than off in-memory state, so the
/// pipeline survives the app going away in the middle. Quitting no longer has
/// to wait for it: the recorders are finalized, the manifest keeps the timings,
/// and `resumePending` picks the session back up at the next launch. Stages are
/// idempotent and each one is recorded as it completes, so a resumed session
/// redoes at most the stage that was interrupted.
final class PostProcessor {
    static let shared = PostProcessor()

    /// Serial: two calls' worth of ffmpeg and whisper at once would just fight
    /// over the same cores, and a backlog after a crash is worked through in
    /// order.
    private let queue = DispatchQueue(label: "com.local.memorai.postprocess", qos: .utility)

    /// Off in the test suite: transcription needs whisper, its model, and
    /// minutes of CPU, none of which belong in `swift test`.
    private let transcriptionEnabled: Bool

    init(transcription: Bool = true) {
        self.transcriptionEnabled = transcription
    }

    /// Blocks until everything queued so far has run.
    func waitUntilIdle() { queue.sync {} }

    // MARK: - The recording gate

    /// Guards `_recordingActive` alone. Deliberately NOT `queue`: the gate is
    /// closed from the main thread at the start of a call, and `queue` can be
    /// sitting inside a whisper run for minutes.
    private let gateLock = NSLock()
    private var _recordingActive = false

    private var isRecordingActive: Bool { gateLock.withLock { _recordingActive } }

    /// Asked by the long stages between their own units of work. Terminating
    /// the child in flight only frees the machine until the stage starts the
    /// next one, and a transcription is dozens of whisper runs long.
    private var pauseCheck: () -> Bool { { [weak self] in self?.isRecordingActive ?? false } }

    /// Open or close the gate. While it is closed nothing heavy runs: the
    /// pipeline stops between stages, and the child process in flight is
    /// terminated.
    ///
    /// Post-processing a previous call used to overlap the next one — measured
    /// on 2026-08-19, whisper ran from 08:17:53 to 08:25:41 across a call that
    /// started at 08:20:12 — and that load is what makes the speakers crackle
    /// mid-conversation. The pipeline is resumable off its manifest, so the
    /// interruption costs only the stage in flight; the call cannot be redone.
    func setRecordingActive(_ active: Bool, dir: URL) {
        gateLock.lock()
        let changed = _recordingActive != active
        _recordingActive = active
        gateLock.unlock()
        guard changed else { return }

        if active {
            ProcessRunner.cancelPostProcessing(reason: "recording started")
            log("[PostProcessor] Gate closed — no post-processing while recording")
        } else {
            log("[PostProcessor] Gate open — resuming any deferred session")
            // A moment of quiet after a call: the recorders have just finalized
            // their files, and starting whisper in the same breath would put
            // the load right back on the machine the user may still be on.
            queue.asyncAfter(deadline: .now() + gateReopenDelay) { [weak self] in
                self?.resumePending(in: dir)
            }
        }
    }

    /// A moment of quiet after a call before the pipeline starts up again.
    /// `var` so the tests do not have to wait it out.
    var gateReopenDelay: TimeInterval = 15

    /// True while a transcription is running (drives the menu bar label).
    private(set) var isTranscribing = false
    var onTranscribingChanged: ((Bool) -> Void)?
    var onTranscriptionDone: (() -> Void)?

    /// Work files that a killed run can leave behind. Each is rebuilt from
    /// scratch by the stage that owns it, so a leftover is always garbage.
    static let temporarySuffixes = [".stitching.m4a", ".muxing.mp4"]

    /// Runs the pipeline for one session. Returns immediately.
    func enqueue(_ manifest: CallSessionManifest, in dir: URL) {
        queue.async { [weak self] in
            self?.run(manifest: manifest, in: dir)
        }
    }

    /// Called at launch: finishes sessions whose post-processing was cut short,
    /// and clears the debris of runs that were killed mid-ffmpeg.
    func resumePending(in dir: URL) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let pending = CallSessionManifest.pending(in: dir)
            self.removeOrphanedWorkFiles(in: dir, keepingSessionsFor: pending)
            guard !pending.isEmpty else { return }
            log("[PostProcessor] \(pending.count) unfinished session(s) from a previous run — resuming")
            for url in pending {
                guard let manifest = CallSessionManifest.load(url) else {
                    log("[PostProcessor] ⚠️ Unreadable manifest \(url.lastPathComponent) — removing")
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                self.run(manifest: manifest, in: dir)
            }
        }
    }

    /// Temp files whose session has no manifest are from a build that predates
    /// manifests, or from a session that already finished — either way nothing
    /// will ever complete them.
    private func removeOrphanedWorkFiles(in dir: URL, keepingSessionsFor pending: [URL]) {
        let liveTags = Set(pending.compactMap {
            CallSessionManifest.load($0)?.tag
        })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            guard name.hasPrefix("call_"),
                  Self.temporarySuffixes.contains(where: { name.hasSuffix($0) }),
                  let tag = CallHistory.parse(filename: name)?.tag,
                  !liveTags.contains(tag) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            log("[PostProcessor] Removed leftover work file \(name)")
        }
    }

    // MARK: - The pipeline

    private func run(manifest input: CallSessionManifest, in dir: URL) {
        guard !isRecordingActive else {
            log("[PostProcessor] Recording in progress — \(input.tag) waits (manifest stays on disk)")
            return
        }

        var manifest = input
        manifest.attempts += 1
        let attempt = manifest.attempts
        manifest.save(in: dir)

        // Name the stage while it runs: these are the heaviest things the app
        // does, and when one of them lands on top of a live call the glitch
        // monitor's overload lines say so by name.
        let steps: [(String, (inout CallSessionManifest, URL) -> Void)] = [
            ("stitch", publishMicTrack),
            ("aec", cancelEcho),
            ("mux", muxVideo),
            ("whisper", transcribe),
        ]
        // Stages that finished on their own merits. A stage cut short by a
        // recording must not be recorded as done — an interrupted AEC otherwise
        // passes for "echo cancellation declined" and the call keeps the raw
        // mic forever, and an interrupted whisper for a finished transcript.
        var completed = input.stages
        var interrupted = false
        _ = ProcessRunner.consumeCancellation()

        for (name, step) in steps {
            if isRecordingActive { interrupted = true; break }
            AudioGlitchMonitor.shared.setStage("\(name) \(manifest.tag)")
            step(&manifest, dir)
            if ProcessRunner.consumeCancellation() || isRecordingActive {
                manifest.stages = completed
                interrupted = true
                log("[PostProcessor] Stage \(name) for \(manifest.tag) cut short by a recording")
                break
            }
            completed = manifest.stages
        }
        AudioGlitchMonitor.shared.setStage(nil)

        if interrupted {
            // Not a failed attempt — the work never got to fail. Charging it
            // would burn the session's retries on interruptions alone.
            manifest.attempts = input.attempts
            manifest.save(in: dir)
            log("[PostProcessor] ⏸ \(manifest.tag) deferred until the recording ends (stages: \(manifest.stages))")
            return
        }

        if manifest.stages.allDone {
            manifest.remove(in: dir)
            log("[PostProcessor] Session \(manifest.tag) complete")
        } else if attempt >= CallSessionManifest.maxAttempts {
            manifest.remove(in: dir)
            Transcriber.discardPartials(tag: manifest.tag, in: dir)
            log("[PostProcessor] ⚠️ Session \(manifest.tag) still unfinished after \(attempt) attempts — giving up (stages: \(manifest.stages))")
        } else {
            manifest.save(in: dir)
            log("[PostProcessor] Session \(manifest.tag) partially processed — will retry at next launch")
        }
    }

    /// Mic part files belonging to `tag`, in recording order. `part10` must
    /// come after `part2`, so the index is compared as a number.
    static func orphanMicParts(names: [String], tag: String) -> [String] {
        let prefix = "call_\(tag)_mic.part"
        return names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix(prefix) else { return nil }
                let rest = name.dropFirst(prefix.count)               // "2.caf"
                guard let dot = rest.firstIndex(of: "."),
                      let index = Int(rest[..<dot]) else { return nil }
                return (index, name)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// A session killed mid-recording never wrote its segment list. The part
    /// files are still there, so hand them to the stitcher and let ffmpeg say
    /// whether anything is salvageable — an m4a killed before its moov atom
    /// was written usually is not, but the LPCM parts are.
    private func adoptOrphanParts(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.recordingFinished, manifest.segments.isEmpty else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let parts = Self.orphanMicParts(names: names, tag: manifest.tag)
        guard !parts.isEmpty else { return }
        log("[PostProcessor] \(manifest.tag) was killed mid-recording — trying to salvage \(parts.count) mic part(s)")
        manifest.segments = parts.map {
            CallSessionManifest.record(.recovered(url: dir.appendingPathComponent($0)))
        }
    }

    private func publishMicTrack(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.micPublished else { return }
        adoptOrphanParts(&manifest, in: dir)
        guard let micURL = manifest.resolve(manifest.micFile, in: dir) else {
            manifest.stages.micPublished = true
            return
        }
        let segments = manifest.micSegments(in: dir)
        guard !segments.isEmpty else {
            // The mic never produced audio (permission denied, no device). Not
            // a failure of this stage — the rest of the session still stands.
            manifest.stages.micPublished = true
            return
        }
        // The stitch may have finished just before the process died, between
        // the rename and the manifest write. Parts gone + track present is
        // success, not a failure to report.
        let partsLeft = segments.contains { FileManager.default.fileExists(atPath: $0.url.path) }
        if !partsLeft, FileManager.default.fileExists(atPath: micURL.path) {
            manifest.stages.micPublished = true
            return
        }

        if MicStitcher.shared.stitch(segments: segments, outputURL: micURL) {
            manifest.stages.micPublished = true
            manifest.save(in: dir)
        } else {
            log("[PostProcessor] ❌ Mic track not assembled for \(manifest.tag) — \(micURL.lastPathComponent) is missing, parts kept: \(segments.map { $0.url.lastPathComponent }.joined(separator: ", "))")
        }
    }

    private func cancelEcho(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.echoCancelled else { return }
        defer {
            // Declining is a decision, not a failure: the stage is done either
            // way, and re-running the model on the next launch would burn
            // minutes of CPU to reach the same verdict.
            manifest.stages.echoCancelled = true
            manifest.save(in: dir)
        }
        guard let micURL = manifest.resolve(manifest.micFile, in: dir),
              let sysURL = manifest.resolve(manifest.systemFile, in: dir),
              FileManager.default.fileExists(atPath: micURL.path),
              EchoCanceller.shared.isAvailable else { return }
        if let cleaned = EchoCanceller.shared.process(micURL: micURL, systemURL: sysURL) {
            manifest.cleanedMicFile = cleaned.lastPathComponent
        }
    }

    private func muxVideo(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.muxed else { return }
        guard let screenURL = manifest.resolve(manifest.screenFile, in: dir),
              FileManager.default.fileExists(atPath: screenURL.path) else {
            manifest.stages.muxed = true       // audio-only session, nothing to mux
            return
        }
        let muxed = AudioMuxer.shared.muxNow(screenURL: screenURL,
                                             micURL: manifest.effectiveMicURL(in: dir),
                                             systemURL: manifest.resolve(manifest.systemFile, in: dir),
                                             micStartSeconds: manifest.micStartSeconds,
                                             systemStartSeconds: manifest.systemStartSeconds,
                                             videoStartSeconds: manifest.videoStartSeconds)
        // "No audio to mux" also ends the stage — retrying cannot conjure a
        // track that was never recorded. Only a real ffmpeg failure retries.
        let hasAudio = [manifest.effectiveMicURL(in: dir), manifest.resolve(manifest.systemFile, in: dir)]
            .contains { $0.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        manifest.stages.muxed = muxed || !hasAudio
        manifest.save(in: dir)
    }

    private func transcribe(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.transcribed else { return }
        guard transcriptionEnabled, SettingsManager.shared.autoTranscribe else {
            manifest.stages.transcribed = true
            return
        }
        guard Transcriber.shared.isAvailable else {
            log("[PostProcessor] Auto-transcribe on but whisper/model missing — skipping")
            manifest.stages.transcribed = true
            return
        }

        setTranscribing(true)
        log("[PostProcessor] Starting transcription for \(manifest.tag)…")
        let done = DispatchSemaphore(value: 0)
        var settled = false
        // Transcribe the cleaned mic but keep naming the session after the
        // canonical file, or the transcript lands next to it under a mangled
        // name. Offsets put both tracks on one timeline so the speaker-labeled
        // transcript interleaves them in the order they were actually spoken.
        Transcriber.shared.transcribeSession(micURL: manifest.effectiveMicURL(in: dir),
                                             systemURL: manifest.resolve(manifest.systemFile, in: dir),
                                             namingURL: manifest.resolve(manifest.micFile, in: dir),
                                             micStartSeconds: manifest.micStartSeconds,
                                             systemStartSeconds: manifest.systemStartSeconds,
                                             videoStartSeconds: manifest.videoStartSeconds,
                                             shouldPause: pauseCheck) { finished in
            settled = finished
            done.signal()
        }
        done.wait()
        setTranscribing(false)
        // Paused for a recording: the finished chunks are on disk and the stage
        // stays open. Recording it as done here would leave the call with the
        // half of the transcript that happened to be ready.
        guard settled else {
            log("[PostProcessor] Transcription for \(manifest.tag) paused — resumes after the recording")
            return
        }
        manifest.stages.transcribed = true
        manifest.save(in: dir)
        log("[PostProcessor] Transcription complete for \(manifest.tag)")
        DispatchQueue.main.async { [weak self] in self?.onTranscriptionDone?() }
    }

    private func setTranscribing(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTranscribing = value
            self.onTranscribingChanged?(value)
        }
    }
}
