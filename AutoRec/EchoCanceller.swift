import Foundation

/// Removes the far side's voice where it leaked from the speakers into the
/// microphone, after the recording has stopped.
///
/// Why not at capture time: Apple voice processing does this live, but it
/// reconfigures the SHARED input device for every other client (measured: the
/// built-in mic's virtual format goes 1ch -> 3ch while it is active) and made
/// real meetings sound bad to the people on the other end. Post-processing
/// cannot touch a live call.
///
/// The raw mic file is never modified. A cleaned copy is written next to it and
/// only used downstream when it measures better than the original — a track
/// with echo is a cosmetic problem, a track with the user's own voice eaten out
/// of it is a destroyed recording.
class EchoCanceller {
    static let shared = EchoCanceller()

    /// What the sidecar reports about the result it produced.
    struct Metrics: Decodable {
        let delaySamples: Int
        let delayMs: Double
        let delayConfidence: Double
        let seconds: Double
        let farSeconds: Double
        let nearSeconds: Double
        /// Echo return loss enhancement: how much quieter the far side's leak
        /// got. Nil when the call had too little far-end audio to judge.
        let erleDb: Double?
        /// Change in the user's own voice level. Nil when they barely spoke.
        let voiceDeltaDb: Double?
        /// Waveform similarity of the user's voice before/after. 1.0 = intact.
        let voiceCorrelation: Double?

        enum CodingKeys: String, CodingKey {
            case delaySamples = "delay_samples"
            case delayMs = "delay_ms"
            case delayConfidence = "delay_confidence"
            case seconds
            case farSeconds = "far_seconds"
            case nearSeconds = "near_seconds"
            case erleDb = "erle_db"
            case voiceDeltaDb = "voice_delta_db"
            case voiceCorrelation = "voice_correlation"
        }
    }

    /// Thresholds are set from measurements on real calls: the model leaves the
    /// voice at -0.07 dB with 0.997 correlation while removing 9-25 dB of echo,
    /// so anything far off that is a malfunction, not a tuning question.
    static let minERLE: Double = 3.0
    static let minERLEWithoutVoiceEvidence: Double = 6.0
    static let maxVoiceLossDb: Double = 1.0
    static let minVoiceCorrelation: Double = 0.90
    /// Enough near/far speech to trust a measurement at all.
    static let minJudgeableSeconds: Double = 1.0

    /// `aec_sidecar.py`'s `MAX_DELAY_SECONDS`, in ms. A delay pinned against
    /// this edge means the true lag is past it, not that it was found there.
    static let delaySearchWindowMs: Double = 1000
    /// Below this the sidecar did not lock onto anything (0.0098 on the
    /// 2026-08-18 call whose real lag was 1422 ms; 0.31–0.34 when it locks).
    static let weakDelayConfidence: Double = 0.05

    private let queue = DispatchQueue(label: "com.local.memorai.aec", qos: .utility)

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    private static let pythonCandidates = [
        // Dedicated venv on a uv-managed standalone CPython, mirroring the OCR
        // sidecar: survives Homebrew python bumps, which wipe site-packages.
        NSString(string: "~/.local/share/memorai-aec/venv/bin/python").expandingTildeInPath,
    ]

    private static let modelPrefix =
        NSString(string: "~/.local/share/memorai-aec/models/dtln_aec_512").expandingTildeInPath

    /// True when the sidecar, its interpreter and the model weights are all
    /// present. Absent installs are not an error: recordings simply keep their
    /// raw mic track.
    var isAvailable: Bool {
        Self.pythonCandidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
            && Self.sidecarScriptPath() != nil
            && FileManager.default.fileExists(atPath: Self.modelPrefix + "_1.tflite")
            && FileManager.default.fileExists(atPath: Self.modelPrefix + "_2.tflite")
    }

    /// Decides whether a result is worth using. Separated out so the rules are
    /// testable without running a model.
    static func verdict(for m: Metrics) -> (accept: Bool, reason: String) {
        if let delta = m.voiceDeltaDb, delta < -maxVoiceLossDb {
            return (false, String(format: "voice lost %.1f dB", -delta))
        }
        if let corr = m.voiceCorrelation, corr < minVoiceCorrelation {
            return (false, String(format: "voice correlation %.2f", corr))
        }
        guard let erle = m.erleDb, m.farSeconds >= minJudgeableSeconds else {
            return (false, "no far-end audio to cancel")
        }
        // With no near-end speech in the call the voice checks above prove
        // nothing, so demand a clearly worthwhile gain before swapping tracks.
        let haveVoiceEvidence = m.nearSeconds >= minJudgeableSeconds && m.voiceDeltaDb != nil
        let required = haveVoiceEvidence ? minERLE : minERLEWithoutVoiceEvidence
        if erle < required {
            return (false, String(format: "only %.1f dB of echo removed", erle))
        }
        return (true, String(format: "%.1f dB echo removed, voice %+.2f dB",
                             erle, m.voiceDeltaDb ?? 0))
    }

    /// Why a weak result is weak. Two unrelated failures produce the same
    /// small ERLE and have opposite fixes, and the number alone has sent this
    /// investigation the wrong way before.
    ///
    /// Either the sidecar never found the lag — it searches ±1 s and a real
    /// call has run 1422 ms out — or it found it and the echo still would not
    /// cancel, which is what recording through open speakers does to a linear
    /// canceller. Nil when the result was good enough to use.
    static func diagnosis(for m: Metrics) -> String? {
        guard let erle = m.erleDb, erle < minERLEWithoutVoiceEvidence else { return nil }
        if m.delayConfidence < weakDelayConfidence || abs(m.delayMs) >= delaySearchWindowMs - 50 {
            return String(format: "lag %+.0f ms at confidence %.3f — that is the edge of the ±1 s search window, so measure the true offset before trusting this number",
                          m.delayMs, m.delayConfidence)
        }
        return String(format: "lag %+.0f ms found at confidence %.2f, so the echo is real and simply will not cancel — open speakers rather than headphones do that, and the mic track keeps a copy of the far side that doubles it in the transcript",
                      m.delayMs, m.delayConfidence)
    }

    /// ffmpeg args to decode any of our call tracks into what the model wants.
    static func buildDecodeArgs(inputPath: String, outPath: String) -> [String] {
        ["-y", "-v", "error", "-i", inputPath, "-ac", "1", "-ar", "16000", outPath]
    }

    static func buildEncodeArgs(inputPath: String, outPath: String) -> [String] {
        ["-y", "-v", "error", "-i", inputPath, "-c:a", "aac", "-b:a", "64k", outPath]
    }

    static func buildSidecarArgs(scriptPath: String, micWav: String, lpbWav: String,
                                 outWav: String, modelPrefix: String) -> [String] {
        [scriptPath, "--mic", micWav, "--lpb", lpbWav, "--out", outWav, "--models", modelPrefix]
    }

    private static func sidecarScriptPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "aec_sidecar", ofType: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("aec_sidecar.py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// Produces `call_<tag>_mic.aec.m4a` and returns it, or nil to keep using
    /// the raw mic. Blocking; call it off the main queue.
    func process(micURL: URL, systemURL: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path), fm.fileExists(atPath: systemURL.path) else {
            return nil
        }
        guard isAvailable,
              let python = Self.pythonCandidates.first(where: { fm.isExecutableFile(atPath: $0) }),
              let script = Self.sidecarScriptPath() else {
            log("[EchoCanceller] Sidecar or model missing — keeping raw mic")
            return nil
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memorai-aec-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? fm.removeItem(at: work) }

        let micWav = work.appendingPathComponent("mic.wav")
        let lpbWav = work.appendingPathComponent("lpb.wav")
        let cleanWav = work.appendingPathComponent("clean.wav")

        for (source, target) in [(micURL, micWav), (systemURL, lpbWav)] {
            let result = ProcessRunner.run(ffmpegPath,
                                           args: Self.buildDecodeArgs(inputPath: source.path,
                                                                      outPath: target.path),
                                           timeout: 300, role: .postProcessing)
            guard result.exitCode == 0 else {
                log("[EchoCanceller] ❌ Decoding \(source.lastPathComponent) failed: \(result.stderrTail)")
                return nil
            }
        }

        log("[EchoCanceller] Cancelling echo in \(micURL.lastPathComponent)…")
        let run = ProcessRunner.run(python,
                                    args: Self.buildSidecarArgs(scriptPath: script,
                                                                micWav: micWav.path,
                                                                lpbWav: lpbWav.path,
                                                                outWav: cleanWav.path,
                                                                modelPrefix: Self.modelPrefix),
                                    timeout: 3600, role: .postProcessing)
        guard run.exitCode == 0, let metrics = Self.parseMetrics(run.stdout) else {
            log("[EchoCanceller] ❌ Sidecar failed (exit \(run.exitCode)): \(run.stderrTail)")
            return nil
        }

        let verdict = Self.verdict(for: metrics)
        log(String(format: "[EchoCanceller] delay %+.0f ms, %@ — %@",
                   metrics.delayMs, verdict.reason, verdict.accept ? "using cleaned mic" : "keeping raw mic"))
        if !verdict.accept, let why = Self.diagnosis(for: metrics) {
            log("[EchoCanceller] \(why)")
        }
        guard verdict.accept else { return nil }

        let cleanURL = micURL.deletingPathExtension()
            .appendingPathExtension("aec")
            .appendingPathExtension(micURL.pathExtension)
        let encode = ProcessRunner.run(ffmpegPath,
                                       args: Self.buildEncodeArgs(inputPath: cleanWav.path,
                                                                  outPath: cleanURL.path),
                                       timeout: 600, role: .postProcessing)
        guard encode.exitCode == 0 else {
            log("[EchoCanceller] ❌ Encoding cleaned mic failed: \(encode.stderrTail)")
            try? fm.removeItem(at: cleanURL)
            return nil
        }
        log("[EchoCanceller] ✅ Wrote \(cleanURL.lastPathComponent)")
        return cleanURL
    }

    static func parseMetrics(_ stdout: String) -> Metrics? {
        // The interpreter prints its own startup noise; take the JSON line.
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { continue }
            if let metrics = try? JSONDecoder().decode(Metrics.self, from: data) {
                return metrics
            }
        }
        return nil
    }
}
