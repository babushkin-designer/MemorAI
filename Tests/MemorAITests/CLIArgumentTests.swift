import XCTest
@testable import MemorAI

final class CLIArgumentTests: XCTestCase {
    func testMissingSearchOptionValuesFailWithoutReadingRuntimeData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli_args_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("memorai")
        // Any accidental defaults access in this fixture fails, rather than
        // reading or writing the user's preferences or recording directory.
        let source = try String(contentsOf: repo.appendingPathComponent("memorai"), encoding: .utf8)
        try ("defaults() { echo 'unexpected defaults access' >&2; return 99; }\n" + source)
            .write(to: fixture, atomically: true, encoding: .utf8)
        for flag in ["--days", "--source", "--limit"] {
            let result = ProcessRunner.run("/bin/bash", args: [fixture.path, "search", "text", flag], timeout: 2)
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.stderr.contains("Missing value for \(flag)"))
            XCTAssertFalse(result.stderr.contains("unexpected defaults access"))
        }
    }
}
