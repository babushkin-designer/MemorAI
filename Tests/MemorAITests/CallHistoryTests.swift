import XCTest
@testable import MemorAI

final class CallHistoryTests: XCTestCase {

    func testParsesTagAndRoleWithUnderscoreHeavyTag() {
        let p = CallHistory.parse(filename: "call_2026-07-09_16-24-44_transcript.txt")
        XCTAssertEqual(p?.tag, "2026-07-09_16-24-44")
        XCTAssertEqual(p?.role, "transcript")
    }

    func testParsesEachRole() {
        XCTAssertEqual(CallHistory.parse(filename: "call_2026-07-09_16-24-44_screen.mp4")?.role, "screen")
        XCTAssertEqual(CallHistory.parse(filename: "call_2026-07-09_16-24-44_mic.m4a")?.role, "mic")
        XCTAssertEqual(CallHistory.parse(filename: "call_2026-07-09_16-24-44_system.m4a")?.role, "system")
        XCTAssertEqual(CallHistory.parse(filename: "call_2026-07-09_16-24-44_summary.md")?.role, "summary")
    }

    func testRejectsNonCallFiles() {
        XCTAssertNil(CallHistory.parse(filename: "clipboard.jsonl"))
        XCTAssertNil(CallHistory.parse(filename: "memorai.log"))
        XCTAssertNil(CallHistory.parse(filename: "call_incomplete"))
    }

    func testWorkFilesAloneDoNotMakeASession() throws {
        // A call that is still running — or one whose stitch failed — leaves
        // only work files behind under its tag. None of them is playable, so
        // the tag must not show up in Recent Calls at all.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_phantomtest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in [
            "call_2026-08-10_12-00-00_mic.part1.caf",
            "call_2026-08-10_12-00-00_session.json",
            "call_2026-08-10_11-00-00_mic.m4a",
        ] {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        let sessions = CallHistory.recentSessions(outputPath: dir.path)
        XCTAssertEqual(sessions.map { $0.tag }, ["2026-08-10_11-00-00"])
    }

    func testGroupsFilesIntoSessions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_calltest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in [
            "call_2026-07-09_10-00-00_mic.m4a",
            "call_2026-07-09_10-00-00_system.m4a",
            "call_2026-07-09_10-00-00_transcript.txt",
            "call_2026-07-08_09-00-00_mic.m4a",
            "call_2026-07-08_09-00-00_screen.mp4",
            "unrelated.txt",
        ] {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        let sessions = CallHistory.recentSessions(outputPath: dir.path)
        XCTAssertEqual(sessions.count, 2)
        // Newest first
        XCTAssertEqual(sessions[0].tag, "2026-07-09_10-00-00")
        XCTAssertNotNil(sessions[0].micURL)
        XCTAssertNotNil(sessions[0].systemURL)
        XCTAssertNotNil(sessions[0].transcriptURL)
        XCTAssertNil(sessions[0].videoURL)
        XCTAssertEqual(sessions[1].tag, "2026-07-08_09-00-00")
        XCTAssertNotNil(sessions[1].videoURL)
        XCTAssertNil(sessions[1].transcriptURL)
    }
}
