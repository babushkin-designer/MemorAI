import XCTest
@testable import MemorAI

final class DialogueTranscriptTests: XCTestCase {

    private func seg(_ fromMs: Int, _ toMs: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(fromMs: fromMs, toMs: toMs, text: text)
    }

    func testInterleavesByStartTime() {
        let mic = [seg(0, 2000, "Привет"), seg(10_000, 12_000, "Да, вижу")]
        let system = [seg(3000, 8000, "Привет, слышно меня?")]
        let out = Transcriber.dialogueTranscript(mic: mic, system: system)
        XCTAssertEqual(out, """
        [00:00] Я: Привет
        [00:03] Собеседник: Привет, слышно меня?
        [00:10] Я: Да, вижу

        """)
    }

    func testGroupsConsecutiveSameSpeaker() {
        let mic = [seg(0, 1000, "Раз."), seg(1500, 2500, "Два.")]
        let system = [seg(60_000, 61_000, "Три.")]
        let out = Transcriber.dialogueTranscript(mic: mic, system: system)
        XCTAssertEqual(out, """
        [00:00] Я: Раз. Два.
        [01:00] Собеседник: Три.

        """)
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(Transcriber.dialogueTranscript(mic: [], system: []), "")
    }

    func testHourTimestampFormat() {
        let line = Transcriber.formatDialogueLine(startMs: 3_723_000, speaker: "Я", text: "тест")
        XCTAssertEqual(line, "[1:02:03] Я: тест")
    }

    func testNonSpeechAnnotationFilter() {
        XCTAssertTrue(Transcriber.isNonSpeechAnnotation("[BLANK_AUDIO]"))
        XCTAssertTrue(Transcriber.isNonSpeechAnnotation("(музыка)"))
        XCTAssertTrue(Transcriber.isNonSpeechAnnotation("*звонок*"))
        XCTAssertFalse(Transcriber.isNonSpeechAnnotation("Обычная речь (с ремаркой)"))
    }

    func testParseWhisperJSON() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":2000},"text":" Привет"},
          {"offsets":{"from":2000,"to":3000},"text":" [BLANK_AUDIO]"},
          {"offsets":{"from":3000,"to":5000},"text":"  Как дела?  "}
        ]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_test_\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = try XCTUnwrap(Transcriber.parseWhisperJSON(url, offsetMs: 600_000))
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].fromMs, 600_000)
        XCTAssertEqual(segs[0].text, "Привет")
        XCTAssertEqual(segs[1].fromMs, 603_000)
        XCTAssertEqual(segs[1].text, "Как дела?")
    }
}
