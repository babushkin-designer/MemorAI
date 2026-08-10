import XCTest
@testable import MemorAI

/// Exercises the real publish path on files ffmpeg actually produced. The
/// canonical `call_<tag>_mic.m4a` must appear only when it holds the whole
/// track — that is the invariant AudioMuxer, Transcriber and the Recent Calls
/// menu all rely on. Skips itself where ffmpeg is not installed.
final class MicStitcherIntegrationTests: XCTestCase {

    private let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private func makeTone(_ url: URL, seconds: Double, frequency: Int, codec: String) {
        let args = ["-y", "-v", "error",
                    "-f", "lavfi",
                    "-i", "sine=frequency=\(frequency):duration=\(seconds):sample_rate=48000",
                    "-c:a", codec, url.path]
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: args).exitCode, 0, "fixture encode failed")
    }

    private func duration(of url: URL) -> Double {
        let out = ProcessRunner.run(ffmpeg, args: ["-hide_banner", "-nostats", "-i", url.path,
                                                   "-f", "null", "-"]).stderr
        guard let m = try? NSRegularExpression(pattern: #"Duration: (\d+):(\d+):(\d+\.\d+)"#)
            .firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) else { return 0 }
        let ns = out as NSString
        return (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 3600
            + (Double(ns.substring(with: m.range(at: 2))) ?? 0) * 60
            + (Double(ns.substring(with: m.range(at: 3))) ?? 0)
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_stitch_it_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSingleSegmentIsPublishedByRenameNotTranscode() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.m4a")
        let part = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part1.m4a")
        makeTone(part, seconds: 3, frequency: 440, codec: "aac")
        let before = try Data(contentsOf: part)

        XCTAssertTrue(MicStitcher.shared.stitch(
            segments: [.init(url: part, firstBufferHostSeconds: 100, frameCount: 48000 * 3, sampleRate: 48000)],
            outputURL: output))

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(try Data(contentsOf: output), before, "the lone segment must be moved, not re-encoded")
    }

    func testTwoSegmentsAreJoinedWithTheEngineRestartHoleBridged() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.m4a")
        let part1 = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part1.m4a")
        // Second segment in a different format — the AirPods case, where AAC
        // cannot hold the new channel count and LPCM is written instead.
        let part2 = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part2.caf")
        makeTone(part1, seconds: 3, frequency: 440, codec: "aac")
        makeTone(part2, seconds: 2, frequency: 660, codec: "pcm_f32le")

        // Segment 2 starts 1.5 s after segment 1 ended — the engine was down.
        XCTAssertTrue(MicStitcher.shared.stitch(segments: [
            .init(url: part1, firstBufferHostSeconds: 100, frameCount: 48000 * 3, sampleRate: 48000),
            .init(url: part2, firstBufferHostSeconds: 104.5, frameCount: 48000 * 2, sampleRate: 48000),
        ], outputURL: output))

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.stitching.m4a").path))
        // 3 s + 1.5 s of bridging silence + 2 s.
        XCTAssertEqual(duration(of: output), 6.5, accuracy: 0.2)
    }

    func testAFailedStitchPublishesNothingAndKeepsTheParts() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.m4a")
        let part1 = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part1.m4a")
        let part2 = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.part2.caf")
        makeTone(part1, seconds: 3, frequency: 440, codec: "aac")
        // Not audio at all — ffmpeg will refuse the job.
        try Data("not audio".utf8).write(to: part2)

        XCTAssertFalse(MicStitcher.shared.stitch(segments: [
            .init(url: part1, firstBufferHostSeconds: 100, frameCount: 48000 * 3, sampleRate: 48000),
            .init(url: part2, firstBufferHostSeconds: 104.5, frameCount: 48000 * 2, sampleRate: 48000),
        ], outputURL: output))

        // The whole point: half a call must never be published as the call.
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.stitching.m4a").path))
        XCTAssertTrue(CallHistory.recentSessions(outputPath: dir.path).isEmpty)
    }
}
