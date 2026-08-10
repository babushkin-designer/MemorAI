import XCTest
@testable import MemorAI

final class MicStitcherTests: XCTestCase {

    // MARK: - gaps

    func testGapIsTheEngineRestartHole() {
        // Segment 1 starts at host 100 s and holds 12 s of audio, so it ends at
        // 112; segment 2's first buffer lands at 113.5 → 1.5 s were lost while
        // the engine came back up on the new device.
        let gaps = MicStitcher.gaps(for: [(100.0, 12.0), (113.5, 30.0)])
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0], 0)
        XCTAssertEqual(gaps[1], 1.5, accuracy: 0.0001)
    }

    func testFirstSegmentNeverGetsPadding() {
        let gaps = MicStitcher.gaps(for: [(100.0, 5.0)])
        XCTAssertEqual(gaps, [0])
    }

    func testSubSampleJitterIsNotPadded() {
        // 8 ms is buffer jitter, not a hole — padding it would add clicks.
        let gaps = MicStitcher.gaps(for: [(100.0, 10.0), (110.008, 5.0)])
        XCTAssertEqual(gaps[1], 0)
    }

    func testOverlappingSegmentsAreNotPadded() {
        let gaps = MicStitcher.gaps(for: [(100.0, 10.0), (109.0, 5.0)])
        XCTAssertEqual(gaps[1], 0)
    }

    func testHugeGapIsClamped() {
        // A paused recording or a host-clock anomaly must not inject minutes
        // of silence into the track.
        let gaps = MicStitcher.gaps(for: [(100.0, 10.0), (100000.0, 5.0)])
        XCTAssertEqual(gaps[1], MicStitcher.maxGapSeconds)
    }

    func testUnknownHostTimeYieldsNoPadding() {
        XCTAssertEqual(MicStitcher.gaps(for: [(100.0, 10.0), (nil, 5.0)])[1], 0)
        XCTAssertEqual(MicStitcher.gaps(for: [(nil, 10.0), (120.0, 5.0)])[1], 0)
    }

    func testNonFiniteValuesNeverReachTheFilterGraph() {
        // NaN survives every comparison, so an unguarded min() would emit
        // `atrim=end=nan` and fail the whole stitch.
        XCTAssertEqual(MicStitcher.gaps(for: [(Double.nan, 10.0), (120.0, 5.0)])[1], 0)
        XCTAssertEqual(MicStitcher.gaps(for: [(100.0, Double.nan), (120.0, 5.0)])[1], 0)
        XCTAssertEqual(MicStitcher.gaps(for: [(100.0, 10.0), (Double.infinity, 5.0)])[1], 0)
    }

    func testPausedSegmentsAreReportedWithoutAStartAndSoAreNotPadded() {
        // MicRecorder nils out a paused segment's start time: paused wall clock
        // is missing from the system track too, so padding it into the mic
        // track would push the two out of sync.
        let gaps = MicStitcher.gaps(for: [(100.0, 10.0), (nil, 5.0), (400.0, 5.0)])
        XCTAssertEqual(gaps[1], 0)
        XCTAssertEqual(gaps[2], 0)
    }

    func testEmptyInputYieldsEmptyGaps() {
        XCTAssertEqual(MicStitcher.gaps(for: []), [])
    }

    func testThreeSegmentsEachGetTheirOwnGap() {
        let gaps = MicStitcher.gaps(for: [(10.0, 5.0), (17.0, 4.0), (23.0, 6.0)])
        XCTAssertEqual(gaps[0], 0)
        XCTAssertEqual(gaps[1], 2.0, accuracy: 0.0001)
        XCTAssertEqual(gaps[2], 2.0, accuracy: 0.0001)
    }

    // MARK: - buildConcatArgs

    func testSingleSegmentIsTranscodedWithoutConcat() {
        // This is how a >2ch LPCM segment — the format AAC refuses to encode —
        // turns into the final m4a.
        let args = MicStitcher.buildConcatArgs(paths: ["a.caf"], gaps: [0], outPath: "o.m4a")!
        let filter = value(after: "-filter_complex", in: args)!
        XCTAssertTrue(filter.contains("[0:a]aresample=48000"), filter)
        XCTAssertFalse(filter.contains("concat"), filter)
        XCTAssertEqual(value(after: "-map", in: args), "[a0]")
        XCTAssertEqual(value(after: "-c:a", in: args), "aac")
        XCTAssertEqual(args.last, "o.m4a")
    }

    func testNoSegmentsIsRejected() {
        XCTAssertNil(MicStitcher.buildConcatArgs(paths: [], gaps: [], outPath: "o.m4a"))
    }

    func testMismatchedGapCountIsRejected() {
        XCTAssertNil(MicStitcher.buildConcatArgs(paths: ["a.m4a", "b.m4a"], gaps: [0], outPath: "o.m4a"))
    }

    func testTwoSegmentsWithGapInsertSilenceBetweenThem() {
        let args = MicStitcher.buildConcatArgs(paths: ["a.m4a", "b.m4a"], gaps: [0, 1.5],
                                               outPath: "o.m4a")!
        let filter = value(after: "-filter_complex", in: args)!
        // Both inputs normalized, silence trimmed to the hole, three parts joined.
        XCTAssertTrue(filter.contains("[0:a]aresample=48000"), filter)
        XCTAssertTrue(filter.contains("[1:a]aresample=48000"), filter)
        XCTAssertTrue(filter.contains("atrim=end=1.500"), filter)
        XCTAssertTrue(filter.contains("[a0][g1][a1]concat=n=3:v=0:a=1[out]"), filter)
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertEqual(value(after: "-map", in: args), "[out]")
        XCTAssertEqual(value(after: "-c:a", in: args), "aac")
        XCTAssertEqual(args.last, "o.m4a")
    }

    func testZeroGapConcatenatesDirectly() {
        let args = MicStitcher.buildConcatArgs(paths: ["a.m4a", "b.m4a"], gaps: [0, 0],
                                               outPath: "o.m4a")!
        let filter = value(after: "-filter_complex", in: args)!
        XCTAssertFalse(filter.contains("anullsrc"), filter)
        XCTAssertTrue(filter.contains("[a0][a1]concat=n=2:v=0:a=1[out]"), filter)
    }

    func testThreeSegmentsWithOneGapOrderPartsCorrectly() {
        let args = MicStitcher.buildConcatArgs(paths: ["a.m4a", "b.m4a", "c.m4a"], gaps: [0, 0, 2.25],
                                               outPath: "o.m4a")!
        let filter = value(after: "-filter_complex", in: args)!
        XCTAssertTrue(filter.contains("[a0][a1][g2][a2]concat=n=4:v=0:a=1[out]"), filter)
        XCTAssertTrue(filter.contains("atrim=end=2.250"), filter)
    }

    func testStderrIsKeptQuietLikeTheOtherFfmpegCallers() {
        let args = MicStitcher.buildConcatArgs(paths: ["a.m4a", "b.m4a"], gaps: [0, 1],
                                               outPath: "o.m4a")!
        XCTAssertEqual(value(after: "-v", in: args), "error")
        XCTAssertTrue(args.contains("-y"))
    }

    // MARK: - Segment

    func testSegmentDurationComesFromFramesAndRate() {
        let seg = MicRecorder.Segment(url: URL(fileURLWithPath: "/tmp/a.m4a"),
                                      firstBufferHostSeconds: 1.0,
                                      frameCount: 48000 * 3, sampleRate: 48000)
        XCTAssertEqual(seg.duration, 3.0, accuracy: 0.0001)
        XCTAssertFalse(seg.isEmpty)
    }

    func testSegmentWithNoFramesIsEmpty() {
        let seg = MicRecorder.Segment(url: URL(fileURLWithPath: "/tmp/a.m4a"),
                                      firstBufferHostSeconds: nil,
                                      frameCount: 0, sampleRate: 48000)
        XCTAssertTrue(seg.isEmpty)
        XCTAssertEqual(seg.duration, 0)
    }

    func testSegmentWithBrokenRateHasNoDuration() {
        let seg = MicRecorder.Segment(url: URL(fileURLWithPath: "/tmp/a.m4a"),
                                      firstBufferHostSeconds: nil,
                                      frameCount: 1000, sampleRate: 0)
        XCTAssertEqual(seg.duration, 0)
    }

    // MARK: - segment naming

    func testPartFilesAreIgnoredByCallHistory() throws {
        // Segment files sit next to the call artifacts (and survive a crash
        // mid-call), so the Recent Calls scanner must not mistake one for the
        // real mic track.
        let parsed = CallHistory.parse(filename: "call_2026-08-10_13-01-23_mic.part2.m4a")
        XCTAssertEqual(parsed?.tag, "2026-08-10_13-01-23")
        XCTAssertEqual(parsed?.role, "mic.part2")

        // The LPCM first segment must be ignored the same way, or a call whose
        // stitch failed would offer an unplayable .caf as its mic track.
        let lpcm = CallHistory.parse(filename: "call_2026-08-10_13-01-23_mic.part1.caf")
        XCTAssertEqual(lpcm?.role, "mic.part1")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_stitchtest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["call_2026-08-10_13-01-23_mic.m4a",
                     "call_2026-08-10_13-01-23_mic.part2.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        let sessions = CallHistory.recentSessions(outputPath: dir.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].micURL?.lastPathComponent, "call_2026-08-10_13-01-23_mic.m4a")
    }

    // MARK: - helpers

    private func value(after flag: String, in args: [String], occurrence: Int = 1) -> String? {
        var seen = 0
        for (i, a) in args.enumerated() where a == flag {
            seen += 1
            if seen == occurrence, i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }
}
