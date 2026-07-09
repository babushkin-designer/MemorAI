import XCTest
@testable import MemorAI

final class LLMClientTests: XCTestCase {

    func testParseContentExtractsTextAndUsage() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"Привет"}}],
         "usage":{"prompt_tokens":12,"completion_tokens":3}}
        """.data(using: .utf8)!
        let parsed = try XCTUnwrap(LLMClient.parseContent(json))
        XCTAssertEqual(parsed.text, "Привет")
        XCTAssertEqual(parsed.tokensIn, 12)
        XCTAssertEqual(parsed.tokensOut, 3)
    }

    func testParseContentRejectsEmptyAndMalformed() {
        XCTAssertNil(LLMClient.parseContent(Data("not json".utf8)))
        XCTAssertNil(LLMClient.parseContent(Data("{\"choices\":[]}".utf8)))
        let empty = Data("{\"choices\":[{\"message\":{\"content\":\"  \"}}]}".utf8)
        XCTAssertNil(LLMClient.parseContent(empty))
    }

    func testInsufficientQuotaIsTerminal() {
        let body = Data("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"x\"}}".utf8)
        let error = LLMClient.errorKind(status: 429, data: body)
        guard case .quotaExhausted = error else {
            return XCTFail("expected quotaExhausted, got \(error)")
        }
        XCTAssertFalse(LLMClient.isRetryable(error))
    }

    func testPlain429IsNotQuotaAndNotRetryable() {
        let error = LLMClient.errorKind(status: 429, data: Data("{\"error\":{\"code\":\"rate_limit_exceeded\"}}".utf8))
        guard case .http(429, _) = error else {
            return XCTFail("expected http(429), got \(error)")
        }
        XCTAssertFalse(LLMClient.isRetryable(error))
    }

    func testServerErrorsRetryTransportRetries() {
        XCTAssertTrue(LLMClient.isRetryable(.http(500, "")))
        XCTAssertTrue(LLMClient.isRetryable(.transport("timeout")))
        XCTAssertFalse(LLMClient.isRetryable(.badResponse))
    }

    func testRequestBodyShape() {
        let body = LLMClient.requestBody(model: "gpt-5.5", system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["max_tokens"] as? Int, 100)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["content"] as? String, "u")
    }
}

final class CallLLMTests: XCTestCase {

    func testSummaryPromptEmbedsTranscript() {
        let p = CallLLM.summaryPrompt(transcript: "[00:01] Я: тестовая реплика")
        XCTAssertTrue(p.user.contains("тестовая реплика"))
        XCTAssertTrue(p.system.contains("Илья"))
    }

    func testFollowupPromptSubstitutesName() {
        let p = CallLLM.followupPrompt(transcript: "t", otherName: "Саша")
        XCTAssertTrue(p.system.contains("Саша"))
        XCTAssertFalse(p.system.contains("неизвестно"))
        let anon = CallLLM.followupPrompt(transcript: "t", otherName: nil)
        XCTAssertTrue(anon.system.contains("неизвестно"))
    }

    func testTruncationKeepsHeadAndTail() {
        let long = String(repeating: "a", count: 150_000)
            + "MIDDLE"
            + String(repeating: "b", count: 150_000)
        let out = CallLLM.truncated(long)
        XCTAssertLessThan(out.count, 300_000)
        XCTAssertTrue(out.hasPrefix("aaa"))
        XCTAssertTrue(out.hasSuffix("bbb"))
        XCTAssertTrue(out.contains("транскрипт сокращён"))
    }
}
