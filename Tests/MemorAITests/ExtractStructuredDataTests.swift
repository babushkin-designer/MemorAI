import XCTest
@testable import MemorAI

final class ExtractStructuredDataTests: XCTestCase {

    func testURLsHttpsLocalhostAndBareDomain() {
        let text = "See https://example.org/page and localhost:3000/x and example.com/path for details."
        let result = OCRProcessor.extractStructuredData(from: text)
        let urls = Set(result.urls)
        XCTAssertTrue(urls.contains("https://example.org/page"), "expected https URL to be present, got \(urls)")
        XCTAssertTrue(urls.contains("http://localhost:3000/x"), "expected localhost URL with http:// prefix, got \(urls)")
        XCTAssertTrue(urls.contains("https://example.com/path"), "expected bare domain URL with https:// prefix, got \(urls)")
    }

    func testEmailExtraction() {
        let text = "Contact a.b+c@test.io for support."
        let result = OCRProcessor.extractStructuredData(from: text)
        XCTAssertTrue(result.emails.contains("a.b+c@test.io"), "expected email to be extracted, got \(result.emails)")
    }

    func testPhoneExtraction() {
        let text = "Call +7 999 123-45-67 anytime."
        let result = OCRProcessor.extractStructuredData(from: text)
        XCTAssertTrue(result.phones.contains("+7 999 123-45-67"), "expected phone to be extracted, got \(result.phones)")
    }

    func testPathExtraction() {
        let text = "Run /usr/local/bin/python3 to start."
        let result = OCRProcessor.extractStructuredData(from: text)
        XCTAssertTrue(result.paths.contains("/usr/local/bin/python3"), "expected path to be extracted, got \(result.paths)")
    }

    func testEmptyStringYieldsAllEmpty() {
        let result = OCRProcessor.extractStructuredData(from: "")
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertTrue(result.emails.isEmpty)
        XCTAssertTrue(result.phones.isEmpty)
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testDuplicateURLsAreDeduplicated() {
        let text = "https://example.org/page https://example.org/page https://example.org/page"
        let result = OCRProcessor.extractStructuredData(from: text)
        XCTAssertEqual(Set(result.urls), Set(["https://example.org/page"]))
        XCTAssertEqual(result.urls.count, 1, "expected exact duplicates to be collapsed to a single entry")
    }
}
