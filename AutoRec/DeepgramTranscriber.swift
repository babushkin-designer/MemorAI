import Foundation

/// Fast cloud transcription for recorded calls.
///
/// The mic and system tracks are already compressed and carry a known role, so
/// they are uploaded independently and concurrently instead of spending time
/// building another mixed file. Their utterances are shifted onto the shared
/// host-clock timeline and merged into the same dialogue format as local
/// Whisper. Push-to-talk dictation does not use this class.
final class DeepgramTranscriber {
    static let shared = DeepgramTranscriber()

    static let keychainService = "deepgram-api-key"
    private let endpoint = "https://api.deepgram.com/v1/listen"
    private let requestTimeout: TimeInterval = 20 * 60
    private let maxAttempts = 2

    enum Outcome {
        case success(URL)
        case unavailable
        case retryableFailure
        case permanentFailure
    }

    struct Utterance: Equatable {
        let fromMs: Int
        let toMs: Int
        let speaker: Int?
        let text: String
    }

    private struct TrackJob {
        let role: String
        let url: URL
        let offsetSeconds: Double
        let diarize: Bool
    }

    private enum TrackResult {
        case success([Utterance], requestID: String?)
        case failure(TrackFailure)
    }

    private struct TrackFailure {
        let reason: String
        let retryable: Bool
        let retryAfter: TimeInterval?
    }

    var isAvailable: Bool { Keychain.read(service: Self.keychainService) != nil }

    /// Synchronous by design: PostProcessor already owns a background queue and
    /// needs the verdict before it records the stage. The two network requests
    /// themselves run concurrently and do not use ProcessRunner, so a new call
    /// can stop local CPU-heavy work without killing an upload already in flight.
    func transcribeSession(micURL: URL?, systemURL: URL?, namingURL: URL?,
                           micStartSeconds: Double?, systemStartSeconds: Double?) -> Outcome {
        guard let key = Keychain.read(service: Self.keychainService) else {
            return .unavailable
        }

        let fm = FileManager.default
        let micExists = micURL.map { fm.fileExists(atPath: $0.path) } ?? false
        let systemExists = systemURL.map { fm.fileExists(atPath: $0.path) } ?? false
        guard micExists || systemExists else {
            log("[Deepgram] No audio tracks to transcribe")
            return .permanentFailure
        }

        let offsets = AudioMuxer.computeOffsets(
            micStart: micExists ? micStartSeconds : nil,
            systemStart: systemExists ? systemStartSeconds : nil,
            videoStart: nil)
        var jobs: [TrackJob] = []
        if micExists, let micURL {
            jobs.append(TrackJob(role: "mic", url: micURL,
                                 offsetSeconds: offsets.mic, diarize: false))
        }
        if systemExists, let systemURL {
            jobs.append(TrackJob(role: "system", url: systemURL,
                                 offsetSeconds: offsets.system, diarize: true))
        }

        log("[Deepgram] Uploading \(jobs.map(\.role).joined(separator: "+")) for transcription…")
        let group = DispatchGroup()
        let resultLock = NSLock()
        var results: [String: TrackResult] = [:]
        for job in jobs {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = transcribeTrack(job, key: key)
                resultLock.withLock { results[job.role] = result }
                group.leave()
            }
        }
        group.wait()

        var labeled: [(utterance: Utterance, label: String)] = []
        for job in jobs {
            guard let result = resultLock.withLock({ results[job.role] }) else {
                log("[Deepgram] ❌ Missing result for \(job.role)")
                return .retryableFailure
            }
            switch result {
            case .failure(let failure):
                log("[Deepgram] ❌ \(job.role) failed: \(failure.reason)")
                return failure.retryable ? .retryableFailure : .permanentFailure
            case .success(let utterances, let requestID):
                let idText = requestID.map { " (request \($0))" } ?? ""
                log("[Deepgram] \(job.role): \(utterances.count) utterance(s)\(idText)")
                let shift = Int((job.offsetSeconds * 1000).rounded())
                for utterance in utterances {
                    let shifted = Utterance(fromMs: max(0, utterance.fromMs + shift),
                                            toMs: max(0, utterance.toMs + shift),
                                            speaker: utterance.speaker,
                                            text: utterance.text)
                    let label: String
                    if job.role == "mic" {
                        label = "Я"
                    } else if let speaker = utterance.speaker {
                        label = "Собеседник \(speaker + 1)"
                    } else {
                        label = "Собеседник"
                    }
                    labeled.append((shifted, label))
                }
            }
        }

        let transcript = Self.render(labeled)
        guard !transcript.isEmpty else {
            log("[Deepgram] ❌ API returned no speech")
            return .permanentFailure
        }
        let reference = namingURL ?? micURL ?? systemURL!
        let output = Transcriber.transcriptURL(for: reference)
        do {
            try transcript.write(to: output, atomically: true, encoding: .utf8)
            Transcriber.shared.deduplicateTranscript(at: output)
            log("[Deepgram] ✅ Transcript saved: \(output.lastPathComponent)")
            return .success(output)
        } catch {
            log("[Deepgram] ❌ Could not save transcript: \(error.localizedDescription)")
            return .retryableFailure
        }
    }

    private func transcribeTrack(_ job: TrackJob, key: String) -> TrackResult {
        var lastFailure = TrackFailure(reason: "unknown error", retryable: true, retryAfter: nil)
        for attempt in 1...maxAttempts {
            let result = upload(job, key: key)
            switch result {
            case .success:
                return result
            case .failure(let failure):
                lastFailure = failure
                guard failure.retryable, attempt < maxAttempts else { return result }
                let delay = failure.retryAfter ?? pow(2, Double(attempt - 1))
                log("[Deepgram] \(job.role) attempt \(attempt)/\(maxAttempts) failed — retrying in \(String(format: "%.1f", delay))s")
                Thread.sleep(forTimeInterval: delay)
            }
        }
        return .failure(lastFailure)
    }

    private func upload(_ job: TrackJob, key: String) -> TrackResult {
        guard let url = Self.requestURL(endpoint: endpoint,
                                        language: SettingsManager.shared.whisperLanguage,
                                        diarize: job.diarize) else {
            return .failure(TrackFailure(reason: "invalid request URL", retryable: false, retryAfter: nil))
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: job.url), forHTTPHeaderField: "Content-Type")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let done = DispatchSemaphore(value: 0)
        var result: TrackResult = .failure(
            TrackFailure(reason: "no response", retryable: true, retryAfter: nil))
        session.uploadTask(with: request, fromFile: job.url) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(TrackFailure(reason: error.localizedDescription,
                                               retryable: true, retryAfter: nil))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(TrackFailure(reason: "empty response", retryable: true, retryAfter: nil))
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let retryable = Self.isRetryable(statusCode: http.statusCode)
                let retryAfter = Self.retryAfterDelay(
                    http.value(forHTTPHeaderField: "Retry-After"))
                result = .failure(TrackFailure(
                    reason: "HTTP \(http.statusCode): \(body.prefix(300))",
                    retryable: retryable,
                    retryAfter: retryAfter))
                return
            }
            guard let parsed = Self.parseResponse(data) else {
                result = .failure(TrackFailure(reason: "unparseable response",
                                               retryable: false, retryAfter: nil))
                return
            }
            result = .success(parsed.utterances, requestID: parsed.requestID)
        }.resume()

        if done.wait(timeout: .now() + requestTimeout + 10) == .timedOut {
            session.invalidateAndCancel()
            return .failure(TrackFailure(reason: "timed out", retryable: true, retryAfter: nil))
        }
        return result
    }

    static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Deepgram currently returns delta-seconds. Missing or malformed headers
    /// fall back to the caller's exponential delay.
    static func retryAfterDelay(_ header: String?) -> TimeInterval? {
        guard let header,
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return seconds
    }

    static func requestURL(endpoint: String, language: String, diarize: Bool) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        var items = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        if diarize {
            items.append(URLQueryItem(name: "diarize_model", value: "latest"))
        }
        if language == "auto" {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        } else {
            items.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = items
        return components.url
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    static func parseResponse(_ data: Data) -> (utterances: [Utterance], requestID: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let raw = results["utterances"] as? [[String: Any]] else { return nil }
        let metadata = root["metadata"] as? [String: Any]
        let requestID = metadata?["request_id"] as? String
        let utterances = raw.compactMap { item -> Utterance? in
            guard let text = item["transcript"] as? String,
                  let start = (item["start"] as? NSNumber)?.doubleValue,
                  let end = (item["end"] as? NSNumber)?.doubleValue else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !Transcriber.isNonSpeechAnnotation(trimmed),
                  !Transcriber.isHallucinatedSegment(trimmed) else { return nil }
            let speaker = (item["speaker"] as? NSNumber)?.intValue
            return Utterance(fromMs: Int((start * 1000).rounded()),
                             toMs: Int((end * 1000).rounded()),
                             speaker: speaker, text: trimmed)
        }
        return (utterances, requestID)
    }

    static func render(_ input: [(utterance: Utterance, label: String)]) -> String {
        Transcriber.dialogueTranscript(input.map {
            (seg: TranscriptSegment(fromMs: $0.utterance.fromMs, toMs: $0.utterance.toMs, text: $0.utterance.text),
             speaker: $0.label)
        })
    }
}
