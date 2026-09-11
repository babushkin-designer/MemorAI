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
    ///
    /// Driven through the real mechanism — a suspended `ProcessRunner`, which
    /// is what a live recording does — rather than a stub, so this covers the
    /// wiring and not just the branch.
    func testPausedRunWritesNoTranscriptAndReportsUnsettled() throws {
        try requireTools()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-01_00-00-00"
        let mic = dir.appendingPathComponent("call_\(tag)_mic.m4a")
        let sys = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeTone(mic, seconds: 3, frequency: 440)
        makeTone(sys, seconds: 3, frequency: 880)

        ProcessRunner.suspendPostProcessing(reason: "test")
        defer { ProcessRunner.resumePostProcessing() }

        let done = expectation(description: "transcription returns")
        var settled = true
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys) { finished in
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

    func testFailedTranscriptWriteKeepsChunksAndReportsUnsettled() throws {
        try requireTools()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-06_00-00-00"
        let mic = dir.appendingPathComponent("call_\(tag)_mic.m4a")
        let sys = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeTone(mic, seconds: 3, frequency: 440)
        makeTone(sys, seconds: 3, frequency: 880)
        let micCache = dir.appendingPathComponent("_whisper_\(tag)_mic_0.json")
        let sysCache = dir.appendingPathComponent("_whisper_\(tag)_system_0.json")
        try seedChunkJSON(micCache, text: "сохранённая мысль")
        try seedChunkJSON(sysCache, text: "сохранённый ответ")

        // A directory at the destination makes the atomic String.write fail
        // without changing permissions on the whole test sandbox.
        let destination = dir.appendingPathComponent("call_\(tag)_transcript.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let done = expectation(description: "transcription returns")
        var settled = true
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys) { finished in
            settled = finished
            done.fulfill()
        }
        wait(for: [done], timeout: 60)

        XCTAssertFalse(settled, "an unpublished transcript must remain retryable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sysCache.path))
    }

    /// A prepared track must not be reused unless it is whole. A truncated one
    /// (a kill or a timeout mid-convert) is far bigger than any header, so size
    /// cannot tell them apart — only the rename can, which is why the convert
    /// writes under a work name.
    func testATruncatedPreparedTrackIsNotReused() throws {
        try requireTools()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = "2026-01-05_00-00-00"
        let mic = dir.appendingPathComponent("call_\(tag)_mic.m4a")
        let sys = dir.appendingPathComponent("call_\(tag)_system.m4a")
        makeTone(mic, seconds: 4, frequency: 440)
        makeTone(sys, seconds: 4, frequency: 880)

        // What a convert killed halfway leaves behind: a real wav header and a
        // fraction of the samples.
        let truncated = dir.appendingPathComponent("_track_\(tag)_mic.wav")
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: [
            "-y", "-v", "error", "-i", mic.path, "-t", "1",
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", truncated.path]).exitCode, 0)
        let truncatedSize = try FileManager.default
            .attributesOfItem(atPath: truncated.path)[.size] as? Int ?? 0

        try seedChunkJSON(dir.appendingPathComponent("_whisper_\(tag)_mic_0.json"), text: "речь")
        try seedChunkJSON(dir.appendingPathComponent("_whisper_\(tag)_system_0.json"), text: "ответ")

        let done = expectation(description: "transcription returns")
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys) { _ in done.fulfill() }
        wait(for: [done], timeout: 120)

        // The stranded file was replaced by a full conversion of the 4 s track,
        // not adopted as if it were one.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("_track_\(tag)_mic.part.wav").path),
            "the work file must not be left behind")
        let text = try String(contentsOf: dir.appendingPathComponent("call_\(tag)_transcript.txt"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("речь"), text)
        XCTAssertGreaterThan(truncatedSize, 44, "fixture must be a plausible truncation, not an empty header")
    }

    /// Retention has to be able to reclaim a cache stranded by a quit during a
    /// pause — nothing else will, and these names do not start with `call_`.
    func testTheChunkCacheIsAKnownWorkFileWithAKnownSession() {
        XCTAssertTrue(RetentionManager.isCallWorkFile("_whisper_2026-09-01_12-12-10_mic_3.json"))
        XCTAssertTrue(RetentionManager.isCallWorkFile("_chunk_2026-09-01_12-12-10_system_0.wav"))
        XCTAssertTrue(RetentionManager.isCallWorkFile("_track_2026-09-01_12-12-10_mic.wav"))
        XCTAssertEqual(RetentionManager.transcriptionCacheTag("_whisper_2026-09-01_12-12-10_mic_3.json"),
                       "2026-09-01_12-12-10")
    }

    /// And it must not mistake a recording for one — deleting those is the
    /// user's call, never a timer's.
    func testRecordingsAreNotWorkFiles() {
        XCTAssertFalse(RetentionManager.isCallWorkFile("call_2026-09-01_12-12-10_mic.m4a"))
        XCTAssertFalse(RetentionManager.isCallWorkFile("call_2026-09-01_12-12-10_transcript.txt"))
        XCTAssertNil(RetentionManager.transcriptionCacheTag("_track_not-a-tag_mic.wav"))
        XCTAssertNil(RetentionManager.transcriptionCacheTag("clipboard.jsonl"))
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
