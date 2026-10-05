import AVFoundation
import XCTest
@testable import MemorAI

final class SystemAudioTimelineTests: XCTestCase {
    func testBoundaryJitterDoesNotAccumulateSilence() {
        var timeline = SystemAudioTimeline()
        for i in 0..<1000 {
            let jitter = i == 0 ? 0 : (i % 2 == 0 ? -0.0002 : 0.0002)
            timeline.record(host: 100 + Double(i) * 0.02 + jitter, duration: 0.02)
        }
        XCTAssertTrue(timeline.gaps.isEmpty)
        XCTAssertEqual(timeline.capturedSeconds, 20, accuracy: 0.000001)
    }

    func testRestorationFailureHasBoundedAttemptsAndKeepsRecoveryMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sys_failure_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var manifest = CallSessionManifest(tag: "failed-timeline")
        manifest.stages.systemTimelineRestored = false
        manifest.recordingFinished = true
        manifest.save(in: dir)
        let processor = PostProcessor(transcription: false)
        processor.transcriptionRetryDelay = 3600
        for attempt in 1...5 {
            processor.enqueue(manifest, in: dir)
            processor.waitUntilIdle()
            let latest = try XCTUnwrap(CallSessionManifest.load(manifest.url(in: dir)))
            XCTAssertEqual(latest.attempts, min(attempt, CallSessionManifest.maxAttempts))
            XCTAssertFalse(latest.stages.micPublished)
            XCTAssertEqual(latest.stages.systemTimelineRestored, false)
        }
        processor.enqueue(manifest, in: dir, resetTranscription: true)
        processor.waitUntilIdle()
        XCTAssertEqual(CallSessionManifest.load(manifest.url(in: dir))?.attempts, 1)
    }
    func testOnlyMissingTimeIsRecordedAndSurvivesSerialization() throws {
        var timeline = SystemAudioTimeline()
        timeline.record(host: 100, duration: 0.5)
        timeline.record(host: 100.5, duration: 0.5)
        timeline.record(host: 162, duration: 1)
        let restored = try JSONDecoder().decode(SystemAudioTimeline.self,
            from: JSONEncoder().encode(timeline))
        XCTAssertEqual(restored.capturedSeconds, 2)
        XCTAssertEqual(restored.gaps.count, 1)
        XCTAssertEqual(restored.gaps[0].position, 1)
        XCTAssertEqual(restored.gaps[0].seconds, 61)
    }

    func testLegacyStagesDecodeWithoutRequiringRestoration() throws {
        let data = Data(#"{"micPublished":true,"echoCancelled":true,"muxed":true,"transcribed":true}"#.utf8)
        let stages = try JSONDecoder().decode(CallSessionManifest.Stages.self, from: data)
        XCTAssertNil(stages.systemTimelineRestored)
        XCTAssertTrue(stages.allDone)
    }

    func testRealRestorationKeepsSilenceAndIsSafeToRetryAfterPublication() throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("ffmpeg unavailable") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sys_timeline_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("system.m4a")
        // A killed copy must never be mistaken for the immutable original.
        try Data([1, 2]).write(to: dir.appendingPathComponent("system.compact.tmp"))
        let generated = ProcessRunner.run(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=2", "-c:a", "aac", url.path])
        XCTAssertEqual(generated.exitCode, 0)
        var timeline = SystemAudioTimeline()
        timeline.record(host: 100, duration: 1)
        timeline.record(host: 162, duration: 1)
        for _ in 0..<2 {
            XCTAssertTrue(timeline.restore(at: url))
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 63, accuracy: 0.05)
            file.framePosition = 48000 * 20
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
            try file.read(into: buffer)
            XCTAssertEqual(buffer.frameLength, 4800)
            XCTAssertLessThan((0..<4800).map { abs(buffer.floatChannelData![0][$0]) }.max()!, 0.001)
        }
    }
}
