import XCTest
@testable import MemorAI

/// The recording gate reaching inside the transcription: a call that starts
/// mid-transcript must stop the whisper loop, keep what it already has, and
/// leave the stage open. Skips itself where ffmpeg/whisper are not installed.
final class TranscriberPauseTests: XCTestCase {

    private let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_pause_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTone(_ url: URL, seconds: Double, frequency: Int) {
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(seconds):sample_rate=48000",
            "-c:a", "aac", url.path]).exitCode, 0, "fixture encode failed")
    }

    /// A whisper `-oj` result, as the chunk cache stores it.
    private func seedChunkJSON(_ url: URL, text: String) throws {
        let json = """
        {"transcription":[{"offsets":{"from":0,"to":1500},"text":" \(text)"}]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func requireTools() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        guard Transcriber.shared.isAvailable else {
            throw XCTSkip("whisper-cli or model not installed")
        }
    }

    /// The whole point of the pause: no transcript file, and the caller is told
    /// the run is not settled. A half-written transcript would be worse than
    /// none — its mere existence makes every later attempt skip the session.
    func testPausedRunWritesNoTranscriptAndReportsUnsettled() throws {
        try requireTools()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"
        let mic = dir.appendingPathComponent("call_\(tag)_mic.m4a")
        let sys = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeTone(mic, seconds: 3, frequency: 440)
        makeTone(sys, seconds: 3, frequency: 880)

        let done = expectation(description: "transcription returns")
        var settled = true
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys,
                                             shouldPause: { true }) { finished in
            settled = finished
            done.fulfill()
        }
        wait(for: [done], timeout: 120)

        XCTAssertFalse(settled, "a paused run must not pass for a finished one")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("call_\(tag)_transcript.txt").path))
    }

    /// The resume: chunks an earlier run got through are read back off disk
    /// instead of costing another pass of the model. Both tracks are seeded
    /// here, so a whisper run at all would blow the (short) timeout.
    func testFinishedChunksAreReusedOnTheNextRun() throws {
        try requireTools()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-02_00-00-00"
        let mic = dir.appendingPathComponent("call_\(tag)_mic.m4a")
        let sys = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeTone(mic, seconds: 3, frequency: 440)
        makeTone(sys, seconds: 3, frequency: 880)
        try seedChunkJSON(dir.appendingPathComponent("_whisper_\(tag)_mic_0.json"), text: "мысль вслух")
        try seedChunkJSON(dir.appendingPathComponent("_whisper_\(tag)_system_0.json"), text: "ответ собеседника")

        let done = expectation(description: "transcription returns")
        var settled = false
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys) { finished in
            settled = finished
            done.fulfill()
        }
        wait(for: [done], timeout: 60)

        XCTAssertTrue(settled)
        let txt = dir.appendingPathComponent("call_\(tag)_transcript.txt")
        let text = try String(contentsOf: txt, encoding: .utf8)
        XCTAssertTrue(text.contains("мысль вслух"), text)
        XCTAssertTrue(text.contains("ответ собеседника"), text)
        // Written transcript, so the cache has nothing left to survive for.
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("_whisper_") || $0.hasPrefix("_chunk_") || $0.hasPrefix("_track_") }
        XCTAssertEqual(left, [], "chunk cache outlived the transcript")
    }

    /// Sweeping the cache must not touch the recordings it sits next to.
    func testDiscardPartialsRemovesOnlyItsOwnWorkFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-03_00-00-00"
        let keep = ["call_\(tag)_mic.m4a", "call_\(tag)_system.m4a",
                    "call_\(tag)_transcript.txt", "call_\(tag)_session.json",
                    "_whisper_2026-01-04_00-00-00_mic_0.json"]
        let drop = ["_whisper_\(tag)_mic_0.json", "_whisper_\(tag)_system_11.json",
                    "_chunk_\(tag)_mic_3.wav", "_track_\(tag)_system.wav"]
        for name in keep + drop {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }

        Transcriber.discardPartials(tag: tag, in: dir)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, Set(keep))
    }
}
