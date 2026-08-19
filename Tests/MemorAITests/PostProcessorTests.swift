import XCTest
@testable import MemorAI

/// The scenario these exist for: on 2026-08-10 the app was quit during a call.
/// ffmpeg had already built `call_<tag>_screen.muxing.mp4` with sound, the
/// atomic swap never happened, and the finished video was left silent — with
/// no way to redo it, because the track timings only lived in memory.
final class PostProcessorTests: XCTestCase {

    private let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    // MARK: - Manifest

    func testManifestRoundTrips() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var manifest = CallSessionManifest(tag: "2026-01-01_00-00-00")
        manifest.micFile = "call_2026-01-01_00-00-00_mic.m4a"
        manifest.systemFile = "call_2026-01-01_00-00-00_system.m4a"
        manifest.screenFile = "call_2026-01-01_00-00-00_screen.mp4"
        manifest.micStartSeconds = 1234.5
        manifest.videoStartSeconds = 1233.4
        manifest.segments = [.init(file: "call_2026-01-01_00-00-00_mic.part1.caf",
                                   firstHostSeconds: 1234.5, frameCount: 96000, sampleRate: 48000)]
        manifest.stages.muxed = true
        XCTAssertTrue(manifest.save(in: dir))

        let loaded = try XCTUnwrap(CallSessionManifest.load(manifest.url(in: dir)))
        XCTAssertEqual(loaded.tag, "2026-01-01_00-00-00")
        XCTAssertEqual(loaded.micStartSeconds, 1234.5)
        XCTAssertEqual(loaded.videoStartSeconds, 1233.4)
        XCTAssertTrue(loaded.stages.muxed)
        XCTAssertFalse(loaded.stages.allDone)
        // The segment survives well enough to hand the stitcher the same job.
        let segments = loaded.micSegments(in: dir)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].url, dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part1.caf"))
        XCTAssertEqual(segments[0].duration, 2.0, accuracy: 0.0001)

        XCTAssertEqual(CallSessionManifest.pending(in: dir).map { $0.lastPathComponent },
                       ["call_2026-01-01_00-00-00_session.json"])
        // Manifests must not show up as calls in the menu.
        XCTAssertTrue(CallHistory.recentSessions(outputPath: dir.path).isEmpty)
    }

    func testCleanedMicIsPreferredWhenPresent() {
        let dir = URL(fileURLWithPath: "/data")
        var manifest = CallSessionManifest(tag: "t")
        manifest.micFile = "mic.m4a"
        XCTAssertEqual(manifest.effectiveMicURL(in: dir)?.lastPathComponent, "mic.m4a")
        manifest.cleanedMicFile = "mic.aec.m4a"
        XCTAssertEqual(manifest.effectiveMicURL(in: dir)?.lastPathComponent, "mic.aec.m4a")
    }

    func testPendingIsOldestFirstSoABacklogRunsInOrder() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for tag in ["2026-01-02_09-00-00", "2026-01-01_09-00-00", "2026-01-01_08-00-00"] {
            CallSessionManifest(tag: tag).save(in: dir)
        }
        XCTAssertEqual(CallSessionManifest.pending(in: dir).map { $0.lastPathComponent }, [
            "call_2026-01-01_08-00-00_session.json",
            "call_2026-01-01_09-00-00_session.json",
            "call_2026-01-02_09-00-00_session.json",
        ])
    }

    // MARK: - Resuming a killed session

    func testAKilledSessionIsFinishedAtTheNextLaunch() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"

        // What the disk looks like after a quit mid-pipeline: a video with no
        // audio, the two source tracks (the mic still under its part name),
        // and the half-written mux temp file.
        let screen = dir.appendingPathComponent("call_\(tag)_screen.mp4")
        let micPart = dir.appendingPathComponent("call_\(tag)_mic.part1.m4a")
        let system = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeSilentVideo(screen, seconds: 4)
        makeTone(micPart, seconds: 3, frequency: 440)
        makeTone(system, seconds: 4, frequency: 300)
        try Data("half a mux".utf8).write(to: dir.appendingPathComponent("call_\(tag)_screen.muxing.mp4"))
        XCTAssertEqual(audioStreams(of: screen), 0, "fixture should start without sound")

        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = "call_\(tag)_mic.m4a"
        manifest.systemFile = "call_\(tag)_system.m4a"
        manifest.screenFile = "call_\(tag)_screen.mp4"
        manifest.micStartSeconds = 1001.0
        manifest.systemStartSeconds = 1000.0
        manifest.videoStartSeconds = 1000.0
        manifest.segments = [.init(file: micPart.lastPathComponent, firstHostSeconds: 1001.0,
                                   frameCount: 48000 * 3, sampleRate: 48000)]
        manifest.recordingFinished = true
        manifest.save(in: dir)

        let processor = PostProcessor(transcription: false)
        processor.resumePending(in: dir)
        processor.waitUntilIdle()

        // The mic track is published under its canonical name…
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("call_\(tag)_mic.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micPart.path))
        // …the video has sound…
        XCTAssertEqual(audioStreams(of: screen), 1)
        // …the temp file is gone and the session is closed out.
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_\(tag)_screen.muxing.mp4").path))
        XCTAssertTrue(CallSessionManifest.pending(in: dir).isEmpty)

        let session = try XCTUnwrap(CallHistory.recentSessions(outputPath: dir.path).first)
        XCTAssertEqual(session.tag, tag)
        XCTAssertNotNil(session.micURL)
        XCTAssertNotNil(session.videoURL)
    }

    func testCompletedStagesAreNotRedone() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"

        let screen = dir.appendingPathComponent("call_\(tag)_screen.mp4")
        let system = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeSilentVideo(screen, seconds: 2)
        makeTone(system, seconds: 2, frequency: 300)
        let before = try Data(contentsOf: screen)

        var manifest = CallSessionManifest(tag: tag)
        manifest.systemFile = system.lastPathComponent
        manifest.screenFile = screen.lastPathComponent
        manifest.stages = .init(micPublished: true, echoCancelled: true, muxed: true, transcribed: true)
        manifest.save(in: dir)

        let processor = PostProcessor(transcription: false)
        processor.resumePending(in: dir)
        processor.waitUntilIdle()

        XCTAssertEqual(try Data(contentsOf: screen), before, "a finished session must not be re-muxed")
        XCTAssertTrue(CallSessionManifest.pending(in: dir).isEmpty)
    }

    func testAStuckSessionIsGivenUpOnRatherThanRetriedForever() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"

        // The mic parts are gone and the track was never published, so this
        // session can never complete. It must not haunt every future launch.
        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = "call_\(tag)_mic.m4a"
        manifest.segments = [.init(file: "call_\(tag)_mic.part1.m4a", firstHostSeconds: 1,
                                   frameCount: 48000, sampleRate: 48000)]
        manifest.save(in: dir)

        let processor = PostProcessor(transcription: false)
        for _ in 0..<CallSessionManifest.maxAttempts {
            processor.resumePending(in: dir)
            processor.waitUntilIdle()
        }
        XCTAssertTrue(CallSessionManifest.pending(in: dir).isEmpty)
    }

    func testOrphanedWorkFilesAreSweptUp() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Debris of a session that already finished (or of a build without
        // manifests) — nothing will ever complete these.
        for name in ["call_2026-01-01_00-00-00_screen.muxing.mp4",
                     "call_2026-01-01_00-00-00_mic.stitching.m4a"] {
            try Data("debris".utf8).write(to: dir.appendingPathComponent(name))
        }
        // …while a live session's temp file is left alone.
        CallSessionManifest(tag: "2026-02-02_00-00-00").save(in: dir)
        let live = dir.appendingPathComponent("call_2026-02-02_00-00-00_screen.muxing.mp4")
        try Data("in flight".utf8).write(to: live)

        let processor = PostProcessor(transcription: false)
        processor.resumePending(in: dir)
        processor.waitUntilIdle()

        XCTAssertFalse(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_2026-01-01_00-00-00_screen.muxing.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.stitching.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - The recording gate

    /// The bug this closes: post-processing a previous call ran straight
    /// through the next call's recording (measured 2026-08-19), and whisper
    /// plus the AEC sidecar on the same machine is what makes the speakers
    /// crackle mid-conversation.
    func testNothingRunsWhileARecordingIsInProgress() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"
        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = "call_\(tag)_mic.m4a"
        manifest.save(in: dir)

        let processor = PostProcessor(transcription: false)
        processor.setRecordingActive(true, dir: dir)
        processor.enqueue(manifest, in: dir)
        processor.waitUntilIdle()

        // Still pending, and the deferral did not cost the session a retry —
        // otherwise a run of interrupted attempts would exhaust maxAttempts and
        // the call would be given up on without ever having been processed.
        let pending = CallSessionManifest.pending(in: dir)
        XCTAssertEqual(pending.count, 1)
        let onDisk = try XCTUnwrap(CallSessionManifest.load(pending[0]))
        XCTAssertEqual(onDisk.attempts, 0)
        XCTAssertFalse(onDisk.stages.micPublished)
    }

    /// And once the call is over the same manifest is picked back up off disk.
    func testWorkResumesAfterTheRecordingEnds() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"
        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = "call_\(tag)_mic.m4a"
        manifest.save(in: dir)

        let processor = PostProcessor(transcription: false)
        processor.gateReopenDelay = 0.1
        processor.setRecordingActive(true, dir: dir)
        processor.enqueue(manifest, in: dir)
        processor.waitUntilIdle()
        XCTAssertEqual(CallSessionManifest.pending(in: dir).count, 1)

        processor.setRecordingActive(false, dir: dir)
        // The gate schedules the resume; nothing here may run before it fires.
        let resumed = expectation(description: "session picked back up")
        DispatchQueue.global().async {
            while CallSessionManifest.pending(in: dir).count == 1 { usleep(50_000) }
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 60)
    }

    // MARK: - helpers

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_postproc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTone(_ url: URL, seconds: Double, frequency: Int) {
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(seconds):sample_rate=48000",
            "-c:a", "aac", url.path]).exitCode, 0)
    }

    private func makeSilentVideo(_ url: URL, seconds: Double) {
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "color=c=black:s=160x120:r=10:d=\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path]).exitCode, 0)
    }

    private func audioStreams(of url: URL) -> Int {
        let out = ProcessRunner.run(ffmpeg, args: ["-hide_banner", "-nostats", "-i", url.path,
                                                   "-f", "null", "-"]).stderr
        // Only the input's streams — ffmpeg reports its own output mapping too.
        let input = out.components(separatedBy: "Output #").first ?? ""
        return input.components(separatedBy: "\n").filter { $0.contains("Stream #") && $0.contains("Audio:") }.count
    }
}
