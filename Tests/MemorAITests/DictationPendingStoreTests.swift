import XCTest
@testable import MemorAI

final class DictationPendingStoreTests: XCTestCase {
    func testAudioRecordedInStoreIsPublishedWithoutMovingOrCopyingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_direct_\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationPendingStore(directory: root)
        let audio = try store.recordingURL()
        try Data([7, 8]).write(to: audio)
        XCTAssertTrue(store.pending().isEmpty) // An unfinished recording is not a completed job.
        let retained = try store.persist(audio, language: "ru")
        XCTAssertEqual(retained, audio)
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertEqual(try Data(contentsOf: audio), Data([7, 8]))
        let metadata = audio.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.persist(audio, language: "ru"))
        XCTAssertEqual(try Data(contentsOf: audio), Data([7, 8]))
    }
    func testDeferredSpeechAndLanguageSurviveStoreRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_pending_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        let directory = root.appendingPathComponent("pending")
        let audio = try DictationPendingStore(directory: directory).persist(source, language: "ru")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let restored = DictationPendingStore(directory: directory)
        XCTAssertEqual(restored.pending().count, 1)
        XCTAssertEqual(restored.pending().first?.1, "ru")
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        restored.remove(audio)
        XCTAssertTrue(restored.pending().isEmpty)
        restored.remove(audio)
    }

    func testFailedPersistenceDoesNotDeleteOriginalSpeech() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_fail_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([2]).write(to: blocked)
        XCTAssertThrowsError(try DictationPendingStore(directory: blocked).persist(source, language: "ru"))
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }
}
