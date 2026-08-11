import XCTest
@testable import MemorAI

final class AudioMuxerTests: XCTestCase {

    // MARK: - computeOffsets

    func testOffsetsRelativeToVideoStart() {
        // SCStream audio came up first, video frame next, mic engine last —
        // the real-world startup order.
        let off = AudioMuxer.computeOffsets(micStart: 100.40, systemStart: 100.27, videoStart: 100.30)
        XCTAssertEqual(off.mic, 0.10, accuracy: 0.0001)
        XCTAssertEqual(off.system, -0.03, accuracy: 0.0001)
    }

    func testOffsetsFallBackToEarliestAudioWithoutVideoStart() {
        let off = AudioMuxer.computeOffsets(micStart: 50.5, systemStart: 50.37, videoStart: nil)
        XCTAssertEqual(off.mic, 0.13, accuracy: 0.0001)
        XCTAssertEqual(off.system, 0, accuracy: 0.0001)
    }

    func testUnknownStartsProduceZeroOffsets() {
        let off = AudioMuxer.computeOffsets(micStart: nil, systemStart: nil, videoStart: nil)
        XCTAssertEqual(off.mic, 0)
        XCTAssertEqual(off.system, 0)
    }

    func testMissingSingleStartIsNotShifted() {
        let off = AudioMuxer.computeOffsets(micStart: nil, systemStart: 20.0, videoStart: 19.9)
        XCTAssertEqual(off.mic, 0)
        XCTAssertEqual(off.system, 0.1, accuracy: 0.0001)
    }

    func testAnomalousOffsetIsDiscarded() {
        // A >10s gap means broken clocks/PTS — mix unshifted rather than
        // delaying a track by minutes.
        let off = AudioMuxer.computeOffsets(micStart: 500.0, systemStart: 100.0, videoStart: 100.0)
        XCTAssertEqual(off.mic, 0)
        XCTAssertEqual(off.system, 0)
    }

    // MARK: - buildMuxArgs

    func testBothTracksNoOffsetsKeepsPlainAmix() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: "y.m4a",
                                           micOffset: 0, sysOffset: 0, outPath: "o.mp4")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 3)
        let filter = value(after: "-filter_complex", in: args)
        XCTAssertEqual(filter, "[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=0[a]")
        XCTAssertEqual(value(after: "-map", in: args, occurrence: 2), "[a]")
    }

    func testPositiveMicOffsetBecomesAdelay() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: "y.m4a",
                                           micOffset: 0.1326, sysOffset: 0, outPath: "o.mp4")
        let filter = value(after: "-filter_complex", in: args)!
        XCTAssertTrue(filter.contains("[1:a]adelay=133:all=1[t0]"), filter)
        XCTAssertTrue(filter.contains("[t0][2:a]amix=inputs=2"), filter)
    }

    func testNegativeOffsetBecomesHeadTrim() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: "y.m4a",
                                           micOffset: 0.2, sysOffset: -0.03, outPath: "o.mp4")
        let filter = value(after: "-filter_complex", in: args)!
        XCTAssertTrue(filter.contains("[1:a]adelay=200:all=1[t0]"), filter)
        XCTAssertTrue(filter.contains("[2:a]atrim=start=0.030,asetpts=PTS-STARTPTS[t1]"), filter)
        XCTAssertTrue(filter.contains("[t0][t1]amix=inputs=2"), filter)
    }

    func testSingleTrackNoOffsetMapsDirectly() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: nil, sysPath: "y.m4a",
                                           micOffset: 0, sysOffset: 0, outPath: "o.mp4")
        XCTAssertFalse(args.contains("-filter_complex"))
        XCTAssertEqual(value(after: "-map", in: args, occurrence: 2), "1:a")
    }

    func testSingleTrackWithOffsetGoesThroughFilter() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: nil,
                                           micOffset: 0.5, sysOffset: 0, outPath: "o.mp4")
        XCTAssertEqual(value(after: "-filter_complex", in: args), "[1:a]adelay=500:all=1[t0]")
        XCTAssertEqual(value(after: "-map", in: args, occurrence: 2), "[t0]")
    }

    func testTinyOffsetsAreIgnored() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: "y.m4a",
                                           micOffset: 0.0005, sysOffset: -0.0004, outPath: "o.mp4")
        let filter = value(after: "-filter_complex", in: args)
        XCTAssertEqual(filter, "[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=0[a]")
    }

    func testVideoCopiedAudioReencoded() {
        let args = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: "y.m4a",
                                           micOffset: 0, sysOffset: 0, outPath: "o.mp4")
        XCTAssertEqual(value(after: "-c:v", in: args), "copy")
        XCTAssertEqual(value(after: "-c:a", in: args), "aac")
        XCTAssertEqual(args.last, "o.mp4")
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
    func testOutputSampleRateIsPinnedSoTheCleanedMicCannotDragItDown() {
        // The echo-cancelled mic is 16 kHz (the model's rate) and amix adopts
        // its FIRST input's rate, so without pinning, the far side's 48 kHz
        // voice was resampled down to 16 kHz on its way into the video.
        // Measured on the 2026-08-11 call: 16000 Hz in the mp4 against 48000
        // on the day the cleaned track was declined.
        let both = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.aec.m4a", sysPath: "y.m4a",
                                           micOffset: 0.1, sysOffset: 0, outPath: "o.mp4")
        XCTAssertEqual(value(after: "-ar", in: both), "48000")

        // Every shape of the graph, including the one with no filter at all.
        let micOnly = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: "m.m4a", sysPath: nil,
                                              micOffset: 0, sysOffset: 0, outPath: "o.mp4")
        XCTAssertFalse(micOnly.contains("-filter_complex"))
        XCTAssertEqual(value(after: "-ar", in: micOnly), "48000")

        let sysShifted = AudioMuxer.buildMuxArgs(screenPath: "s.mp4", micPath: nil, sysPath: "y.m4a",
                                                 micOffset: 0, sysOffset: -0.5, outPath: "o.mp4")
        XCTAssertEqual(value(after: "-ar", in: sysShifted), "48000")
    }

}
