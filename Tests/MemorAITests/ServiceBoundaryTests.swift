import XCTest
@testable import MemorAI

final class ServiceBoundaryTests: XCTestCase {
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
