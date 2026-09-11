import XCTest
@testable import MemorAI

final class HallucinationFilterTests: XCTestCase {

    // MARK: - isHallucinatedSegment (whole segment/line)

    func testExactOutroPhrasesMatch() {
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Продолжение следует..."))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Продолжение следует…"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("ПРОДОЛЖЕНИЕ СЛЕДУЕТ"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment(" Спасибо за просмотр! "))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("До новых встреч!"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("To be continued..."))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Thanks for watching!"))
    }

    func testSubtitleCreditsMatch() {
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Субтитры сделал DimaTorzok"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Субтитры создавал DimaTorzok"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Редактор субтитров А.Синецкая Корректор А.Егорова"))
        XCTAssertTrue(Transcriber.isHallucinatedSegment("Subtitles by the Amara.org community"))
    }

    func testRealSpeechIsKept() {
        XCTAssertFalse(Transcriber.isHallucinatedSegment("Я закончил мысль и все"))
        XCTAssertFalse(Transcriber.isHallucinatedSegment("Продолжение следует в следующем спринте"))
        XCTAssertFalse(Transcriber.isHallucinatedSegment("Спасибо за помощь с кейсом"))
        XCTAssertFalse(Transcriber.isHallucinatedSegment("Обсудили субтитры для ролика"))
        XCTAssertFalse(Transcriber.isHallucinatedSegment(""))
        XCTAssertFalse(Transcriber.isHallucinatedSegment("..."))
    }

    // MARK: - stripTrailingHallucinations (flat dictation text)

    func testStripsTrailingOutroFromFlatText() {
        XCTAssertEqual(
            Transcriber.stripTrailingHallucinations("Я закончил мысль и все. Продолжение следует..."),
            "Я закончил мысль и все.")
    }

    func testStripsStackedOutros() {
        XCTAssertEqual(
            Transcriber.stripTrailingHallucinations("Итог понятен. Продолжение следует… Спасибо за просмотр!"),
            "Итог понятен.")
    }

    func testKeepsPhraseUsedInsideSentence() {
        let s = "продолжение следует завтра после обеда"
        XCTAssertEqual(Transcriber.stripTrailingHallucinations(s), s)
    }

    func testWholeTextOutroBecomesEmpty() {
        XCTAssertEqual(Transcriber.stripTrailingHallucinations("Продолжение следует..."), "")
    }

    func testTextWithoutOutroUntouched() {
        let s = "Обычная фраза без концовки"
        XCTAssertEqual(Transcriber.stripTrailingHallucinations(s), s)
    }

    // MARK: - integration points

    func testCleanDictationTextDropsOutroLine() {
        let raw = "Первая строка мысли\nПродолжение следует...\n"
        XCTAssertEqual(DictationManager.cleanDictationText(raw), "Первая строка мысли")
    }

    func testCleanDictationTextStripsInlineTrailingOutro() {
        let raw = "Мысль закончена. Продолжение следует..."
        XCTAssertEqual(DictationManager.cleanDictationText(raw), "Мысль закончена.")
    }

    func testParseWhisperJSONDropsHallucinatedSegment() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":1000},"text":" Реальная речь про проект"},
          {"offsets":{"from":1000,"to":2000},"text":" Продолжение следует..."}
        ]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let segs = Transcriber.parseWhisperJSON(url, offsetMs: 0)
        XCTAssertEqual(segs?.map { $0.text }, ["Реальная речь про проект"])
    }

    func testDeduplicateTranscriptDropsOutroLine() throws {
        let content = "Реальная строка разговора\nПродолжение следует...\nЕще одна реальная строка"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        Transcriber.shared.deduplicateTranscript(at: url)

        let result = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertEqual(result.components(separatedBy: "\n"),
                       ["Реальная строка разговора", "Еще одна реальная строка"])
    }
}
