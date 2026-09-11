import XCTest
@testable import MemorAI

final class DeepgramTranscriberTests: XCTestCase {

    func testRequestUsesNovaThreeAndRussian() throws {
        let url = try XCTUnwrap(DeepgramTranscriber.requestURL(
            endpoint: "https://api.deepgram.com/v1/listen", language: "ru", diarize: true))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(values["model"], "nova-3")
        XCTAssertEqual(values["language"], "ru")
        XCTAssertNil(values["diarize"], "Deepgram rejects diarize together with diarize_model")
        XCTAssertEqual(values["diarize_model"], "latest")
        XCTAssertNil(values["detect_language"])
    }

    func testOnlyTransientHTTPFailuresAreRetried() {
        XCTAssertFalse(DeepgramTranscriber.isRetryable(statusCode: 400))
        XCTAssertFalse(DeepgramTranscriber.isRetryable(statusCode: 401))
        XCTAssertFalse(DeepgramTranscriber.isRetryable(statusCode: 403))
        XCTAssertTrue(DeepgramTranscriber.isRetryable(statusCode: 408))
        XCTAssertTrue(DeepgramTranscriber.isRetryable(statusCode: 429))
        XCTAssertTrue(DeepgramTranscriber.isRetryable(statusCode: 503))
        XCTAssertEqual(DeepgramTranscriber.retryAfterDelay("7"), 7)
        XCTAssertNil(DeepgramTranscriber.retryAfterDelay(nil))
        XCTAssertNil(DeepgramTranscriber.retryAfterDelay("later"))
    }

    func testAutoLanguageUsesDetection() throws {
        let url = try XCTUnwrap(DeepgramTranscriber.requestURL(
            endpoint: "https://api.deepgram.com/v1/listen", language: "auto", diarize: false))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "detect_language", value: "true")))
        XCTAssertFalse(query.contains { $0.name == "language" })
        XCTAssertFalse(query.contains { $0.name == "diarize" })
    }

    func testParsesUtterancesAndFiltersNonSpeech() throws {
        let data = Data("""
        {
          "metadata": {"request_id": "request-123"},
          "results": {"utterances": [
            {"start": 1.25, "end": 2.5, "speaker": 0, "transcript": " Привет! "},
            {"start": 3, "end": 4, "speaker": 1, "transcript": "[музыка]"},
            {"start": 5, "end": 6.1, "speaker": 1, "transcript": "Как дела?"}
          ]}
        }
        """.utf8)
        let parsed = try XCTUnwrap(DeepgramTranscriber.parseResponse(data))
        XCTAssertEqual(parsed.requestID, "request-123")
        XCTAssertEqual(parsed.utterances, [
            .init(fromMs: 1250, toMs: 2500, speaker: 0, text: "Привет!"),
            .init(fromMs: 5000, toMs: 6100, speaker: 1, text: "Как дела?"),
        ])
    }

    func testRendersTracksInTimelineOrderAndGroupsShortRuns() {
        let input: [(utterance: DeepgramTranscriber.Utterance, label: String)] = [
            (.init(fromMs: 1100, toMs: 2200, speaker: nil, text: "Да."), "Я"),
            (.init(fromMs: 0, toMs: 900, speaker: 0, text: "Привет."), "Собеседник 1"),
            (.init(fromMs: 2500, toMs: 3200, speaker: nil, text: "Согласен."), "Я"),
        ]
        XCTAssertEqual(DeepgramTranscriber.render(input), """
        [00:00] Собеседник 1: Привет.
        [00:01] Я: Да. Согласен.

        """)
    }

    func testContentTypes() {
        XCTAssertEqual(DeepgramTranscriber.contentType(for: URL(fileURLWithPath: "/a/call.m4a")), "audio/mp4")
        XCTAssertEqual(DeepgramTranscriber.contentType(for: URL(fileURLWithPath: "/a/call.wav")), "audio/wav")
    }

    func testCloudAndLocalTranscribersShareOutputNaming() {
        let mic = URL(fileURLWithPath: "/calls/call_2026-01-01_12-00-00_mic.m4a")
        XCTAssertEqual(Transcriber.sessionTag(for: mic), "2026-01-01_12-00-00")
        XCTAssertEqual(Transcriber.transcriptURL(for: mic).path,
                       "/calls/call_2026-01-01_12-00-00_transcript.txt")
    }
}
