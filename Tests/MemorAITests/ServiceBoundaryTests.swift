import XCTest
@testable import MemorAI

final class ServiceBoundaryTests: XCTestCase {
    func testPublishedMicSurvivesInterruptedPartCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mic_cleanup_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var manifest = CallSessionManifest(tag: "cleanup")
        manifest.micFile = "call_cleanup_mic.m4a"
        manifest.recordingFinished = true
        manifest.segments = [
            .init(file: "call_cleanup_mic.part1.m4a", firstHostSeconds: 100, frameCount: 48000, sampleRate: 48000),
            .init(file: "call_cleanup_mic.part2.m4a", firstHostSeconds: 101, frameCount: 48000, sampleRate: 48000),
        ]
        let canonical = dir.appendingPathComponent(manifest.micFile!)
        let whole = Data("complete published track".utf8)
        try whole.write(to: canonical)
        try Data("tail".utf8).write(to: dir.appendingPathComponent(manifest.segments[1].file))
        CallMediaService().publishMicTrack(&manifest, in: dir)
        XCTAssertEqual(try Data(contentsOf: canonical), whole)
        XCTAssertTrue(manifest.stages.micPublished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(manifest.segments[1].file).path))
    }

    func testTitleBatchStopsOnQuotaAndSuspendsAutomaticTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota_batch_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for tag in ["a", "b", "c"] {
            try Data("transcript".utf8).write(to: dir.appendingPathComponent("call_\(tag)_transcript.txt"))
        }
        var requests = 0 // Written on service queue, read after waitUntilIdle.
        let service = CallLLMService(titleDelay: 0) { _ in
            requests += 1
            return .failure(.quotaExhausted)
        }
        let alerted = expectation(description: "quota reported")
        service.onQuotaExhausted = { alerted.fulfill() }
        XCTAssertTrue(service.generateMissingTitles(outputPath: dir.path))
        service.waitUntilIdle()
        service.autoTitle(tag: "b", outputPath: dir.path)
        service.waitUntilIdle()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(service.isBusy)
        wait(for: [alerted], timeout: 1)
    }
    func testDisabledTranscriptionServiceSkipsWithoutTouchingProviders() throws {
        let dir = FileManager.default.temporaryDirectory
        let manifest = CallSessionManifest(tag: "service-boundary")
        let service = CallTranscriptionService(enabled: false)

        let outcome = service.transcribe(manifest, in: dir, recordingActive: { false })

        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(service.isTranscribing)
    }

    func testLLMServiceResolvesAnExactCallFromTheLibrary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_service_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tag = "2026-09-11_01-00-00"
        let transcript = dir.appendingPathComponent("call_\(tag)_transcript.txt")
        try Data("hello".utf8).write(to: transcript)

        let session = try XCTUnwrap(CallLLMService().session(tag: tag, outputPath: dir.path))

        XCTAssertEqual(session.tag, tag)
        XCTAssertEqual(session.transcriptURL, transcript)
    }
}
