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
        var manifest = input
        manifest.attempts += 1
        let attempt = manifest.attempts
        manifest.save(in: dir)

        publishMicTrack(&manifest, in: dir)
        cancelEcho(&manifest, in: dir)
        muxVideo(&manifest, in: dir)
        transcribe(&manifest, in: dir)

        if manifest.stages.allDone {
            manifest.remove(in: dir)
            log("[PostProcessor] Session \(manifest.tag) complete")
        } else if attempt >= CallSessionManifest.maxAttempts {
            manifest.remove(in: dir)
            log("[PostProcessor] ⚠️ Session \(manifest.tag) still unfinished after \(attempt) attempts — giving up (stages: \(manifest.stages))")
        } else {
            manifest.save(in: dir)
            log("[PostProcessor] Session \(manifest.tag) partially processed — will retry at next launch")
        }
    }

    private func publishMicTrack(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.micPublished else { return }
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
        // Transcribe the cleaned mic but keep naming the session after the
        // canonical file, or the transcript lands next to it under a mangled
        // name. Offsets put both tracks on one timeline so the speaker-labeled
        // transcript interleaves them in the order they were actually spoken.
        Transcriber.shared.transcribeSession(micURL: manifest.effectiveMicURL(in: dir),
                                             systemURL: manifest.resolve(manifest.systemFile, in: dir),
                                             namingURL: manifest.resolve(manifest.micFile, in: dir)) {
            done.signal()
        }
        done.wait()
        setTranscribing(false)
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
