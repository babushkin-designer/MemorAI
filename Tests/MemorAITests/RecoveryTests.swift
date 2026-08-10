import XCTest
@testable import MemorAI

/// What is left on disk when the process dies mid-call, and who cleans it up.
final class RecoveryTests: XCTestCase {

    // MARK: - Adopting orphaned mic parts

    func testOrphanPartsComeBackInRecordingOrder() {
        let names = [
            "call_2026-01-01_00-00-00_mic.part10.m4a",
            "call_2026-01-01_00-00-00_mic.part2.caf",
            "call_2026-01-01_00-00-00_mic.part1.m4a",
            "call_2026-01-01_00-00-00_system.m4a",
            "call_2026-01-02_00-00-00_mic.part1.m4a",   // another call
            "memorai.log",
        ]
        XCTAssertEqual(PostProcessor.orphanMicParts(names: names, tag: "2026-01-01_00-00-00"), [
            "call_2026-01-01_00-00-00_mic.part1.m4a",
            "call_2026-01-01_00-00-00_mic.part2.caf",
            "call_2026-01-01_00-00-00_mic.part10.m4a",
        ])
    }

    func testOrphanScanIgnoresNamesItCannotOrder() {
        let names = ["call_t_mic.partX.m4a", "call_t_mic.part.m4a", "call_t_mic.part3.m4a"]
        XCTAssertEqual(PostProcessor.orphanMicParts(names: names, tag: "t"), ["call_t_mic.part3.m4a"])
    }

    func testRecoveredSegmentHasUnknownLengthButIsNotEmpty() {
        // A part file found on disk still holds audio; treating "length
        // unknown" as "nothing here" would throw the salvage away.
        let seg = MicRecorder.Segment.recovered(url: URL(fileURLWithPath: "/tmp/a.caf"))
        XCTAssertFalse(seg.isEmpty)
        XCTAssertEqual(seg.duration, 0)
        XCTAssertNil(seg.firstBufferHostSeconds)
        // No host times → nothing to bridge, so the parts are joined directly.
        XCTAssertEqual(MicStitcher.gaps(for: [(nil, 0), (nil, 0)]), [0, 0])
    }

    func testAKilledRecordingSalvagesItsMicParts() throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_recovery_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"

        // Killed mid-call: the manifest was written at start and never updated,
        // so it carries no segment list at all.
        let part = dir.appendingPathComponent("call_\(tag)_mic.part1.m4a")
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2:sample_rate=48000",
            "-c:a", "aac", part.path]).exitCode, 0)

        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = "call_\(tag)_mic.m4a"
        manifest.save(in: dir)
        XCTAssertFalse(manifest.recordingFinished)

        let processor = PostProcessor(transcription: false)
        processor.resumePending(in: dir)
        processor.waitUntilIdle()

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_\(tag)_mic.m4a").path))
        XCTAssertTrue(CallSessionManifest.pending(in: dir).isEmpty)
    }

    // MARK: - Retention

    func testOnlyWorkFilesAreSweepable() {
        XCTAssertTrue(RetentionManager.isCallWorkFile("call_2026-01-01_00-00-00_mic.part1.m4a"))
        XCTAssertTrue(RetentionManager.isCallWorkFile("call_2026-01-01_00-00-00_mic.part2.caf"))
        XCTAssertTrue(RetentionManager.isCallWorkFile("call_2026-01-01_00-00-00_mic.stitching.m4a"))
        XCTAssertTrue(RetentionManager.isCallWorkFile("call_2026-01-01_00-00-00_screen.muxing.mp4"))

        // Recordings and everything derived from them are the user's data.
        for keep in ["call_2026-01-01_00-00-00_mic.m4a",
                     "call_2026-01-01_00-00-00_mic.aec.m4a",
                     "call_2026-01-01_00-00-00_system.m4a",
                     "call_2026-01-01_00-00-00_screen.mp4",
                     "call_2026-01-01_00-00-00_transcript.txt",
                     "call_2026-01-01_00-00-00_summary.md",
                     "call_2026-01-01_00-00-00_session.json",
                     "clipboard.jsonl"] {
            XCTAssertFalse(RetentionManager.isCallWorkFile(keep), keep)
        }
    }
}
