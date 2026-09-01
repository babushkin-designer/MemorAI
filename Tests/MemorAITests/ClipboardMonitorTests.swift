import XCTest
@testable import MemorAI

/// A copy is only "kept" once it is on disk. The shared jsonl append has to
/// report failure, or ClipboardMonitor advances past an entry it never wrote.
final class ClipboardMonitorTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_clip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAppendCreatesThenGrowsTheFileOneLinePerEntry() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clipboard.jsonl")

        try JSONLWriter.appendNow(["content": "первая", "type": "text"], to: url)
        try JSONLWriter.appendNow(["content": "вторая", "type": "text"], to: url)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("первая"))
        XCTAssertTrue(lines[1].contains("вторая"))
    }

    /// The signal the retry depends on: an append that cannot land must throw.
    func testAppendToAnUnwritablePathThrows() {
        let url = URL(fileURLWithPath: "/no/such/directory/clipboard.jsonl")
        XCTAssertThrowsError(try JSONLWriter.appendNow(["content": "x"], to: url))
    }

    /// Content that cannot be serialised must not take the file down with it.
    func testUnserialisableEntryThrowsRatherThanCorruptingTheFile() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clipboard.jsonl")
        try JSONLWriter.appendNow(["content": "хорошая"], to: url)

        XCTAssertThrowsError(try JSONLWriter.appendNow(["content": Date()], to: url))

        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "a rejected entry must leave the file as it was")
    }
}
