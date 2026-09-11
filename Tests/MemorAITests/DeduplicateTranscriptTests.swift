import XCTest
@testable import MemorAI

final class DeduplicateTranscriptTests: XCTestCase {

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func readFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testFiveIdenticalConsecutiveLinesCollapseToOne() throws {
        let lines = Array(repeating: "hello world this is a repeated line", count: 5)
        let url = try writeTempFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        Transcriber.shared.deduplicateTranscript(at: url)

        let result = readFile(url).components(separatedBy: "\n")
        XCTAssertEqual(result.count, 1, "expected exact consecutive duplicates collapsed to 1 line, got \(result)")
    }

    func testFourLinesSharingLongPrefixCollapseToOne() throws {
        // Each line shares a 15+ char prefix but differs afterward, so pass 1
        // (exact dup collapse) won't touch them; pass 2 (near-dup run of 3+)
        // should collapse the run to its first line.
        let lines = [
            "this is a shared prefix and then variant one",
            "this is a shared prefix and then variant two",
            "this is a shared prefix and then variant three",
            "this is a shared prefix and then variant four",
        ]
        let url = try writeTempFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        Transcriber.shared.deduplicateTranscript(at: url)

        let result = readFile(url).components(separatedBy: "\n")
        XCTAssertEqual(result.count, 1, "expected near-duplicate run of 4 collapsed to 1 line, got \(result)")
        XCTAssertEqual(result.first, lines.first)
    }

    func testTwoLinesSharingPrefixRunTooShortAreKept() throws {
        // Run length of 2 is below the 3+ threshold, so both lines must survive.
        let lines = [
            "this is a shared prefix and then variant one",
            "this is a shared prefix and then variant two",
        ]
        let url = try writeTempFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        Transcriber.shared.deduplicateTranscript(at: url)

        let result = readFile(url).components(separatedBy: "\n")
        XCTAssertEqual(result, lines, "expected both lines kept when near-duplicate run length < 3")
    }

    func testInterleavedDistinctLinesAreUntouched() throws {
        let lines = [
            "the quick brown fox jumps",
            "a completely different sentence here",
            "yet another unrelated line of text",
            "something totally unlike the others",
        ]
        let url = try writeTempFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        Transcriber.shared.deduplicateTranscript(at: url)

        let result = readFile(url).components(separatedBy: "\n")
        XCTAssertEqual(result, lines, "expected distinct interleaved lines to remain untouched")
    }
}
