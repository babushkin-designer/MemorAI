import AVFoundation
import XCTest
@testable import MemorAI

final class MicCapturePipelineTests: XCTestCase {
    // The tuple lets each test own its pipeline, directory and format together.
    private func fixture(capacity: Int = 4, frameCapacity: AVAudioFrameCount = 8192,
                         write: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { try $0.write(from: $1) }) throws
        // swiftlint:disable:next large_tuple
        -> (MicCapturePipeline, URL, AVAudioFormat) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mic_pipeline_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // Three channels select lossless CAF; no encoder priming in assertions.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let pipeline = try MicCapturePipeline(format: format, capacity: capacity, frameCapacity: frameCapacity,
            urlForPart: { index, _ in dir.appendingPathComponent("part\(index).caf") }, write: write)
        return (pipeline, dir, format)
    }
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 480, value: Float = 0.25) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for c in 0..<Int(format.channelCount) {
            for f in 0..<Int(frames) { b.floatChannelData![c][f] = value }
        }
        return b
    }

    func testBlockedSinkDoesNotBlockProducerAndCopiesOwnedPCM() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var first = true // Writer queue only.
        let (pipe, _, format) = try fixture(capacity: 2) { file, pcm in
            if first { first = false; entered.signal(); release.wait() }
            try file.write(from: pcm)
        }
        let input = buffer(format)
        XCTAssertTrue(pipe.submit(input, host: 100))
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        // Sink is still blocked: this returns and fills the second slot.
        XCTAssertTrue(pipe.submit(input, host: 100.01))
        XCTAssertFalse(pipe.submit(input, host: 100.02))
        for c in 0..<3 { for i in 0..<480 { input.floatChannelData![c][i] = -0.75 } }
        release.signal()
        let result = pipe.finish()
        XCTAssertEqual(result.stats.droppedFrames, 480)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].frameCount, 1440) // Dropped tail becomes silence.
        let file = try AVAudioFile(forReading: result.segments[0].url)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1440)!
        try file.read(into: pcm)
        XCTAssertEqual(pcm.floatChannelData![0][0], 0.25)
        XCTAssertEqual(pcm.floatChannelData![0][480], 0.25)
        XCTAssertEqual(pcm.floatChannelData![0][960], 0)
        XCTAssertEqual(pipe.finish().segments.count, 1) // Idempotent drain/finalize.
    }

    func testLongPauseIsBridgedExactlyOnceWithoutWritingSilenceLive() throws {
        let (pipe, _, format) = try fixture()
        XCTAssertTrue(pipe.submit(buffer(format), host: 100))
        pipe.setPaused(true)
        XCTAssertFalse(pipe.submit(buffer(format), host: 200))
        pipe.setPaused(false)
        XCTAssertTrue(pipe.submit(buffer(format), host: 3700))
        let result = pipe.finish()
        XCTAssertEqual(result.segments.map(\.frameCount), [480, 480])
        XCTAssertEqual(result.stats.gaps, 0)
        XCTAssertEqual(result.stats.droppedFrames, 0)
        XCTAssertTrue(result.segments[1].preservesGap)
        let gaps = MicStitcher.gaps(for: result.segments.map { ($0.firstBufferHostSeconds, $0.duration) },
                                   preserve: result.segments.map(\.preservesGap))
        XCTAssertEqual(gaps[1], 3599.99, accuracy: 0.00001)
    }

    func testPauseBeforeFirstBufferDoesNotPrependOrShiftTrack() throws {
        let (pipe, _, format) = try fixture()
        pipe.setPaused(true)
        pipe.setPaused(false)
        XCTAssertTrue(pipe.submit(buffer(format), host: 400))
        pipe.setPaused(true)
        let result = pipe.finish()
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].frameCount, 480)
        XCTAssertEqual(result.segments[0].firstBufferHostSeconds, 400)
    }

    func testActualCaptureGapBecomesMeasuredUncappedSegmentGap() throws {
        let (pipe, _, format) = try fixture()
        XCTAssertTrue(pipe.submit(buffer(format), host: 100))
        XCTAssertTrue(pipe.submit(buffer(format), host: 160))
        let result = pipe.finish()
        XCTAssertEqual(result.stats.gaps, 1)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertTrue(result.segments[1].preservesGap)
        XCTAssertEqual(result.segments[1].firstBufferHostSeconds, 160)
    }

    func testWrongFormatIsRejectedWithOneRecovery() throws {
        let (pipe, _, format) = try fixture(frameCapacity: 32)
        let recovery = expectation(description: "coalesced recovery")
        recovery.assertForOverFulfill = true
        pipe.onRecovery = { recovery.fulfill() }
        XCTAssertTrue(pipe.submit(buffer(format, frames: 64), host: 100))
        let other = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        XCTAssertFalse(pipe.submit(buffer(other, frames: 16), host: 100.1))
        _ = pipe.finish()
        wait(for: [recovery], timeout: 3)
    }

    func testFiveSinkErrorsPostOnlyOneRecovery() throws {
        struct Broken: Error {}
        let (pipe, _, format) = try fixture(capacity: 8) { _, _ in throw Broken() }
        let recovery = expectation(description: "one recovery")
        recovery.assertForOverFulfill = true
        pipe.onRecovery = { recovery.fulfill() }
        for i in 0..<7 { XCTAssertTrue(pipe.submit(buffer(format), host: 100 + Double(i) * 0.01)) }
        XCTAssertTrue(pipe.finish().segments.isEmpty)
        wait(for: [recovery], timeout: 3)
    }

    func testPauseAcrossRestartPreservesGapAndManifestMetadata() throws {
        let (before, _, format) = try fixture()
        XCTAssertTrue(before.submit(buffer(format), host: 100))
        before.setPaused(true)
        let first = before.finish().segments
        let (after, _, nextFormat) = try fixture()
        after.setPaused(true)
        after.setPaused(false)
        XCTAssertTrue(after.submit(buffer(nextFormat), host: 220))
        var second = after.finish().segments[0]
        second.preservesGap = true // Recorder carries a pause across engine generations.
        let segments = first + [second]
        let records = segments.map(CallSessionManifest.record)
        let decoded = try JSONDecoder().decode([CallSessionManifest.SegmentRecord].self,
                                              from: JSONEncoder().encode(records))
        XCTAssertEqual(decoded[1].preservesGap, true)
        let gaps = MicStitcher.gaps(for: segments.map { ($0.firstBufferHostSeconds, $0.duration) },
                                   preserve: segments.map(\.preservesGap))
        XCTAssertEqual(gaps[1], 119.99, accuracy: 0.00001)
    }
    func testNativeMonoAACIsFinalizedAndReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mic_aac_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let pipe = try MicCapturePipeline(format: format, urlForPart: { i, _ in
            dir.appendingPathComponent("part\(i).m4a")
        })
        XCTAssertTrue(pipe.submit(buffer(format, frames: 1600), host: 100))
        let result = pipe.finish()
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].sampleRate, 16000)
        XCTAssertEqual(result.segments[0].frameCount, 1600)
        let file = try AVAudioFile(forReading: result.segments[0].url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testLongPausePartsAreActuallyStitchedToWholeTimeline() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            throw XCTSkip("ffmpeg unavailable")
        }
        let (pipe, dir, format) = try fixture()
        XCTAssertTrue(pipe.submit(buffer(format, frames: 4800), host: 100))
        pipe.setPaused(true)
        pipe.setPaused(false)
        XCTAssertTrue(pipe.submit(buffer(format, frames: 4800), host: 161))
        let result = pipe.finish()
        let output = dir.appendingPathComponent("complete.m4a")
        XCTAssertTrue(MicStitcher.shared.stitch(segments: result.segments, outputURL: output))
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 61.1, accuracy: 0.1)
    }

    func testLargeBufferIsSplitIntoOwnedSlotsWithoutRestart() throws {
        let (pipe, _, format) = try fixture(capacity: 4, frameCapacity: 32)
        pipe.onRecovery = { XCTFail("large buffer is not a format error") }
        XCTAssertTrue(pipe.submit(buffer(format, frames: 100), host: 100))
        let result = pipe.finish()
        XCTAssertEqual(result.stats.droppedFrames, 0)
        XCTAssertEqual(result.segments.map(\.frameCount), [100])
    }

    func testSmallGapKeepsOnePartAndPadsExactFrames() throws {
        let (pipe, _, format) = try fixture()
        XCTAssertTrue(pipe.submit(buffer(format), host: 100))
        XCTAssertTrue(pipe.submit(buffer(format), host: 100.02))
        let result = pipe.finish()
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].frameCount, 1440)
    }

    func testTimestampJitterDoesNotInsertSamplesOrChangeDuration() throws {
        let (pipe, _, format) = try fixture(capacity: 16)
        for i in 0..<10 {
            let jitter = i == 0 ? 0 : (i % 2 == 0 ? -0.001 : 0.001)
            XCTAssertTrue(pipe.submit(buffer(format), host: 100 + Double(i) * 0.01 + jitter))
        }
        let result = pipe.finish()
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].frameCount, 4800)
        XCTAssertEqual(result.stats.droppedFrames, 0)
    }

}
