import XCTest
@testable import MemorAI

final class EchoCancellerTests: XCTestCase {

    private func metrics(erle: Double?, voiceDelta: Double?, correlation: Double?,
                         far: Double = 30, near: Double = 30) -> EchoCanceller.Metrics {
        EchoCanceller.Metrics(delaySamples: -2697, delayMs: -168.6, delayConfidence: 0.18,
                              seconds: 90, farSeconds: far, nearSeconds: near,
                              erleDb: erle, voiceDeltaDb: voiceDelta, voiceCorrelation: correlation)
    }

    // MARK: - verdict

    func testRealMeasuredResultIsAccepted() {
        // The numbers the model actually produced on a real call.
        let v = EchoCanceller.verdict(for: metrics(erle: 9.26, voiceDelta: -0.07, correlation: 0.997))
        XCTAssertTrue(v.accept, v.reason)
    }

    func testVoiceLossRejectsTheResult() {
        // anlms scored like this: more echo removed, but it ate the user.
        let v = EchoCanceller.verdict(for: metrics(erle: 7.8, voiceDelta: -4.4, correlation: 0.95))
        XCTAssertFalse(v.accept)
        XCTAssertTrue(v.reason.contains("voice lost"), v.reason)
    }

    func testMangledWaveformRejectsTheResultEvenAtEqualLoudness() {
        // Same RMS, different signal — the voice was replaced, not preserved.
        let v = EchoCanceller.verdict(for: metrics(erle: 20, voiceDelta: -0.1, correlation: 0.4))
        XCTAssertFalse(v.accept)
        XCTAssertTrue(v.reason.contains("correlation"), v.reason)
    }

    func testNothingRemovedIsNotWorthSwappingTracks() {
        // What happens when the tracks are not aligned: voice fine, no echo gone.
        let v = EchoCanceller.verdict(for: metrics(erle: 0.7, voiceDelta: -0.1, correlation: 0.998))
        XCTAssertFalse(v.accept)
    }

    func testHeadphoneCallWithNoEchoKeepsRawMic() {
        let v = EchoCanceller.verdict(for: metrics(erle: nil, voiceDelta: -0.05, correlation: 0.999,
                                                   far: 0.2))
        XCTAssertFalse(v.accept)
        XCTAssertTrue(v.reason.contains("far-end"), v.reason)
    }

    func testWithoutNearEndSpeechAHigherBarIsRequired() {
        // The user never spoke, so the voice checks prove nothing. A modest
        // gain is not worth swapping in a resampled track…
        let weak = EchoCanceller.verdict(for: metrics(erle: 4.0, voiceDelta: nil, correlation: nil,
                                                      near: 0))
        XCTAssertFalse(weak.accept)
        // …but a large one is.
        let strong = EchoCanceller.verdict(for: metrics(erle: 24.7, voiceDelta: nil, correlation: nil,
                                                        near: 0))
        XCTAssertTrue(strong.accept, strong.reason)
    }

    func testBorderlineVoiceLossIsStillAccepted() {
        let v = EchoCanceller.verdict(for: metrics(erle: 12, voiceDelta: -0.9, correlation: 0.93))
        XCTAssertTrue(v.accept, v.reason)
    }

    // MARK: - parseMetrics

    func testParsesTheSidecarsJsonPastInterpreterNoise() {
        let stdout = """
        INFO: Created TensorFlow Lite XNNPACK delegate for CPU.
        {"delay_samples": -2697, "delay_ms": -168.5625, "delay_confidence": 0.18, "seconds": 90.0, \
        "far_seconds": 13.5, "near_seconds": 10.25, "erle_db": 9.26, "voice_delta_db": -0.07, \
        "voice_correlation": 0.997}
        """
        let m = EchoCanceller.parseMetrics(stdout)
        XCTAssertEqual(m?.delaySamples, -2697)
        XCTAssertEqual(m?.erleDb ?? 0, 9.26, accuracy: 0.001)
        XCTAssertEqual(m?.voiceCorrelation ?? 0, 0.997, accuracy: 0.001)
    }

    func testNullMetricsSurviveDecoding() {
        let stdout = """
        {"delay_samples": 0, "delay_ms": 0, "delay_confidence": 0.0, "seconds": 5.0, \
        "far_seconds": 0.0, "near_seconds": 0.0, "erle_db": null, "voice_delta_db": null, \
        "voice_correlation": null}
        """
        let m = EchoCanceller.parseMetrics(stdout)
        XCTAssertNotNil(m)
        XCTAssertNil(m?.erleDb)
        XCTAssertFalse(EchoCanceller.verdict(for: m!).accept)
    }

    func testGarbageOutputIsNotMistakenForMetrics() {
        XCTAssertNil(EchoCanceller.parseMetrics("Traceback (most recent call last):\nRuntimeError"))
        XCTAssertNil(EchoCanceller.parseMetrics(""))
    }

    // MARK: - ffmpeg arguments

    func testDecodeProducesWhatTheModelRequires() {
        let args = EchoCanceller.buildDecodeArgs(inputPath: "in.m4a", outPath: "out.wav")
        XCTAssertEqual(value(after: "-ar", in: args), "16000")
        XCTAssertEqual(value(after: "-ac", in: args), "1")
        XCTAssertEqual(args.last, "out.wav")
    }

    func testSidecarArgsCarryBothTracksAndTheModel() {
        let args = EchoCanceller.buildSidecarArgs(scriptPath: "s.py", micWav: "m.wav",
                                                  lpbWav: "l.wav", outWav: "c.wav",
                                                  modelPrefix: "/models/dtln_aec_512")
        XCTAssertEqual(args.first, "s.py")
        XCTAssertEqual(value(after: "--mic", in: args), "m.wav")
        XCTAssertEqual(value(after: "--lpb", in: args), "l.wav")
        XCTAssertEqual(value(after: "--out", in: args), "c.wav")
        XCTAssertEqual(value(after: "--models", in: args), "/models/dtln_aec_512")
    }

    // MARK: - helpers

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
