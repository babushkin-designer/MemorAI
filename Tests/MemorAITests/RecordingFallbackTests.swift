import XCTest
@testable import MemorAI

final class RecordingFallbackTests: XCTestCase {
    private final class SystemStub: SystemAudioRecorder {
        var started = false
        var stopped = false
        override func start() async throws { started = true }
        override func stop() async { stopped = true }
    }
    private final class MicFailure: MicRecorder {
        override func start() throws { throw MicRecorderError.noMicAvailable }
    }

    @MainActor
    func testMicStartFailureKeepsSystemRecordingAndFinalizesSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("record_fallback_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = SystemStub(audioURL: dir.appendingPathComponent("system.m4a"), videoURL: nil)
        let processor = PostProcessor(transcription: false)
        let manager = RecordingManager(postProcessor: processor,
            transcriptionService: CallTranscriptionService(enabled: false), outputDirectory: dir,
            makeSystemRecorder: { _, _ in system }, makeMicRecorder: { MicFailure(outputURL: $0) })
        let started = expectation(description: "system-only session running")
        manager.onStateChange = { if $0 == .recording { started.fulfill() } }
        manager.startRecording()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(system.started)
        XCTAssertFalse(system.stopped)
        XCTAssertEqual(manager.state, .recording)
        let stopped = expectation(description: "writers finalized")
        var finalized: CallSessionManifest?
        manager.stopRecording {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if let json = files.first(where: { $0.lastPathComponent.hasSuffix("_session.json") }) {
                finalized = CallSessionManifest.load(json)
            }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(system.stopped)
        XCTAssertEqual(manager.state, .idle)
        processor.waitUntilIdle()
        let manifest = try XCTUnwrap(finalized)
        XCTAssertNil(manifest.micFile)
        XCTAssertTrue(manifest.recordingFinished)
    }
}
