import Foundation

/// Everything that happens to a call after the recorders have stopped:
/// publish the mic track, transcribe it, then optionally clean the recording
/// and mux its audio into the video. The user-facing transcript goes first;
/// playback enhancements must never hold it hostage.
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

    private let transcriptionService: CallTranscriptionService
    private let mediaService: CallMediaService

    init(transcription: Bool = true,
         transcriptionService: CallTranscriptionService? = nil,
         mediaService: CallMediaService = .shared) {
        self.transcriptionService = transcriptionService
            ?? (transcription ? .shared : CallTranscriptionService(enabled: false))
        self.mediaService = mediaService
    }

    /// Blocks until everything queued so far has run.
    func waitUntilIdle() { queue.sync {} }

    // MARK: - The recording gate

    /// Guards `_recordingActive` alone. Deliberately NOT `queue`: the gate is
    /// closed from the main thread at the start of a call, and `queue` can be
    /// sitting inside a whisper run for minutes.
    private let gateLock = NSLock()
    private var _recordingActive = false

    /// Accessed only on `queue`. Retryable cloud/local failures are retried in
    /// the running app instead of waiting for its next launch.
    private var retryableTranscriptionTags: Set<String> = []
    private var scheduledRetries: Set<String> = []
    var transcriptionRetryDelay: TimeInterval = 30

    private var isRecordingActive: Bool { gateLock.withLock { _recordingActive } }

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
            // Suspend, not just cancel: the runner then refuses to start the
            // next chunk too, so a stage in the middle of dozens of whisper
            // runs stops at the first one instead of at the last.
            ProcessRunner.suspendPostProcessing(reason: "recording started")
            log("[PostProcessor] Gate closed — no post-processing while recording")
        } else {
            ProcessRunner.resumePostProcessing()
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

    /// Work files that a killed run can leave behind. Each is rebuilt from
    /// scratch by the stage that owns it, so a leftover is always garbage.
    static let temporarySuffixes = [".stitching.m4a", ".muxing.mp4", ".timeline.m4a",
                                    ".timeline.filter.txt", ".compact.tmp", ".compact.m4a"]

    /// Runs the pipeline for one session. Returns immediately.
    func enqueue(_ manifest: CallSessionManifest, in dir: URL,
                 resetTranscription: Bool = false) {
        // Queue identity, not a frozen manifest value. A manual request can be
        // made while an earlier run is still saving stages; applying its reset
        // on this serial queue avoids clobbering that newer progress.
        let url = manifest.url(in: dir)
        if !FileManager.default.fileExists(atPath: url.path) { manifest.save(in: dir) }
        queue.async { [weak self] in
            guard let self else { return }
            if resetTranscription {
                guard var latest = CallSessionManifest.load(url) else { return }
                latest.attempts = 0
                latest.stages.transcribed = false
                latest.save(in: dir)
            }
            self.processBatch([url], in: dir)
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
            let readable = pending.filter { url in
                guard let manifest = CallSessionManifest.load(url) else {
                    log("[PostProcessor] ⚠️ Unreadable manifest \(url.lastPathComponent) — removing")
                    try? FileManager.default.removeItem(at: url)
                    return false
                }
                return !self.scheduledRetries.contains(manifest.tag)
            }
            self.processBatch(readable, in: dir)
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

    private enum Phase {
        case transcription
        case media
    }

    /// Every pending call gets its transcript pass before any call enters the
    /// slower playback-only AEC/mux pass. This prevents one old recording from
    /// holding the rest of a recovered backlog behind hours of enhancement.
    private func processBatch(_ urls: [URL], in dir: URL) {
        let transcriptSteps: [(String, (inout CallSessionManifest, URL) -> Void)] = [
            ("system timeline", mediaService.restoreSystemTimeline),
            ("stitch", mediaService.publishMicTrack),
            ("transcribe", transcribe),
        ]
        let mediaSteps: [(String, (inout CallSessionManifest, URL) -> Void)] = [
            ("system timeline", mediaService.restoreSystemTimeline),
            ("aec", mediaService.cancelEcho),
            ("mux", mediaService.muxVideo),
        ]

        for url in urls {
            guard let manifest = CallSessionManifest.load(url) else { continue }
            run(manifest: manifest, in: dir, steps: transcriptSteps, phase: .transcription)
        }
        for url in urls {
            guard let manifest = CallSessionManifest.load(url) else { continue }
            run(manifest: manifest, in: dir, steps: mediaSteps, phase: .media)
        }
    }

    private func run(manifest input: CallSessionManifest, in dir: URL,
                     steps: [(String, (inout CallSessionManifest, URL) -> Void)],
                     phase: Phase) {
        guard !isRecordingActive else {
            log("[PostProcessor] Recording in progress — \(input.tag) waits (manifest stays on disk)")
            return
        }
        if input.stages.systemTimelineRestored == false {
            // Only the transcript pass retries restoration. Never spend a
            // second attempt immediately in the playback pass of the same batch.
            if case .media = phase { return }
            if input.attempts >= CallSessionManifest.maxAttempts {
                log("[PostProcessor] System timeline for \(input.tag) needs manual retry — sources and manifest retained")
                return
            }
        }

        var manifest = input
        if case .transcription = phase { manifest.attempts += 1 }
        let attempt = manifest.attempts
        manifest.save(in: dir)
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
            let cancelled = ProcessRunner.consumeCancellation()
            if cancelled {
                manifest.stages = completed
                interrupted = true
                log("[PostProcessor] Stage \(name) for \(manifest.tag) cut short by a recording")
                break
            }
            completed = manifest.stages
            if manifest.stages.systemTimelineRestored == false {
                // Downstream timestamps are invalid until restoration succeeds.
                if isRecordingActive { interrupted = true; break }
                if manifest.save(in: dir), attempt < CallSessionManifest.maxAttempts {
                    scheduleRetry(for: manifest, in: dir)
                }
                AudioGlitchMonitor.shared.setStage(nil)
                log("[PostProcessor] System timeline failed for \(manifest.tag) (attempt \(attempt)); sources retained")
                return
            }
            if isRecordingActive {
                // A network-only Deepgram upload already in flight is allowed
                // to finish. Preserve it, then stop before local heavy work.
                interrupted = true
                log("[PostProcessor] Recording began after \(name) for \(manifest.tag) completed")
                break
            }
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

        guard case .media = phase else {
            manifest.save(in: dir)
            return
        }

        if manifest.stages.allDone {
            guard manifest.save(in: dir) else { return }
            mediaService.discardCompactSystemTrack(manifest, in: dir)
            retryableTranscriptionTags.remove(manifest.tag)
            manifest.remove(in: dir)
            log("[PostProcessor] Session \(manifest.tag) complete")
        } else if attempt >= CallSessionManifest.maxAttempts {
            retryableTranscriptionTags.remove(manifest.tag)
            mediaService.discardCompactSystemTrack(manifest, in: dir)
            manifest.remove(in: dir)
            Transcriber.discardPartials(tag: manifest.tag, in: dir)
            log("[PostProcessor] ⚠️ Session \(manifest.tag) still unfinished after \(attempt) attempts — giving up (stages: \(manifest.stages))")
        } else {
            manifest.save(in: dir)
            if retryableTranscriptionTags.contains(manifest.tag) {
                scheduleRetry(for: manifest, in: dir)
                log("[PostProcessor] Session \(manifest.tag) partially processed — retry scheduled")
            } else {
                log("[PostProcessor] Session \(manifest.tag) partially processed — will retry at next launch")
            }
        }
    }

    private func scheduleRetry(for manifest: CallSessionManifest, in dir: URL) {
        guard scheduledRetries.insert(manifest.tag).inserted else { return }
        let url = manifest.url(in: dir)
        queue.asyncAfter(deadline: .now() + transcriptionRetryDelay) { [weak self] in
            guard let self else { return }
            self.scheduledRetries.remove(manifest.tag)
            guard !self.isRecordingActive,
                  FileManager.default.fileExists(atPath: url.path) else { return }
            self.processBatch([url], in: dir)
        }
    }

    private func transcribe(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.transcribed else { return }
        switch transcriptionService.transcribe(manifest, in: dir, recordingActive: { isRecordingActive }) {
        case .completed:
            retryableTranscriptionTags.remove(manifest.tag)
            manifest.stages.transcribed = true
            manifest.save(in: dir)
        case .skipped:
            manifest.stages.transcribed = true
        case .paused:
            log("[PostProcessor] Transcription for \(manifest.tag) paused — resumes after the recording")
        case .retryableFailure:
            retryableTranscriptionTags.insert(manifest.tag)
            log("[PostProcessor] Transcription for \(manifest.tag) failed temporarily")
        case .permanentFailure:
            log("[PostProcessor] Transcription for \(manifest.tag) failed permanently")
        }
    }
}
