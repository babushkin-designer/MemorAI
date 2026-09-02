import XCTest
@testable import MemorAI

/// The capture-health line is what a glitchy call gets read off later, so a
/// clean session must not print gaps it did not have, and a lossy one must name
/// every kind of loss it did.
final class CaptureStatsTests: XCTestCase {

    func testCleanSessionReportsOnlyCounts() {
        var stats = SystemAudioRecorder.CaptureStats()
        stats.audioBuffers = 1000
        stats.videoFrames = 500

        let summary = stats.summary
        XCTAssertEqual(summary, "audio 1000 buffers, video 500 frames")
        XCTAssertFalse(summary.contains("gap"))
        XCTAssertFalse(summary.contains("dropped"))
    }

    func testLossesAreAllNamed() {
        var stats = SystemAudioRecorder.CaptureStats()
        stats.audioBuffers = 900
        stats.audioGaps = 3
        stats.audioGapSeconds = 0.25
        stats.audioMaxGapSeconds = 0.12
        stats.audioNotReady = 2
        stats.videoFrames = 400
        stats.videoNotReady = 5
        stats.videoIncomplete = 7

        let summary = stats.summary
        XCTAssertTrue(summary.contains("3 PTS gap(s)"), summary)
        XCTAssertTrue(summary.contains("0.250s missing"), summary)
        XCTAssertTrue(summary.contains("max 0.120s"), summary)
        XCTAssertTrue(summary.contains("2 audio buffer(s) dropped"), summary)
        XCTAssertTrue(summary.contains("5 frame(s) dropped"), summary)
        XCTAssertTrue(summary.contains("7 incomplete frame(s)"), summary)
    }
}
