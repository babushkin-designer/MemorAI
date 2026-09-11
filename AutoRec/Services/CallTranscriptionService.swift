import Foundation

enum CallTranscriptionOutcome: Equatable {
    case completed
    case skipped
    case paused
    case retryableFailure
    case permanentFailure
}

/// Owns call-transcription provider selection and execution.
///
/// The post-processing scheduler only needs the outcome of this stage. It does
/// not need to know which provider ran, how local Whisper waits for completion,
/// or when falling back from Deepgram is appropriate.
final class CallTranscriptionService {
    static let shared = CallTranscriptionService()

    private let enabled: Bool
    private(set) var isTranscribing = false
    var onStateChanged: ((Bool) -> Void)?
    var onCompleted: ((String) -> Void)?

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func transcribe(_ manifest: CallSessionManifest, in dir: URL,
                    recordingActive: () -> Bool) -> CallTranscriptionOutcome {
        guard enabled, SettingsManager.shared.autoTranscribe else { return .skipped }

        let deepgramAvailable = SettingsManager.shared.useDeepgramForCalls
            && DeepgramTranscriber.shared.isAvailable
        let localAvailable = Transcriber.shared.isAvailable
        guard deepgramAvailable || localAvailable else {
            log("[CallTranscription] Neither Deepgram nor local Whisper is available — skipping")
            return .skipped
        }

        setTranscribing(true)
        log("[CallTranscription] Starting transcription for \(manifest.tag)…")

        let micURL = manifest.resolve(manifest.micFile, in: dir)
        let systemURL = manifest.resolve(manifest.systemFile, in: dir)
        var deepgramWasRetryable = false

        if deepgramAvailable {
            switch DeepgramTranscriber.shared.transcribeSession(
                micURL: micURL,
                systemURL: systemURL,
                namingURL: micURL ?? systemURL,
                micStartSeconds: manifest.micStartSeconds,
                systemStartSeconds: manifest.systemStartSeconds) {
            case .success:
                return finish(.completed, tag: manifest.tag)
            case .retryableFailure:
                deepgramWasRetryable = true
                log("[CallTranscription] Deepgram failed temporarily — falling back to local Whisper")
            case .unavailable, .permanentFailure:
                log("[CallTranscription] Deepgram unavailable/rejected the request — falling back to local Whisper")
            }
        }

        guard localAvailable else {
            let outcome: CallTranscriptionOutcome = deepgramWasRetryable
                ? .retryableFailure
                : .permanentFailure
            return finish(outcome, tag: manifest.tag)
        }

        let done = DispatchSemaphore(value: 0)
        var completed = false
        // Raw tracks intentionally bypass playback-only AEC. They preserve
        // speaker separation and keep transcription off the slow media path.
        Transcriber.shared.transcribeSession(
            micURL: micURL,
            systemURL: systemURL,
            namingURL: micURL ?? systemURL,
            micStartSeconds: manifest.micStartSeconds,
            systemStartSeconds: manifest.systemStartSeconds,
            videoStartSeconds: manifest.videoStartSeconds
        ) { success in
            completed = success
            done.signal()
        }
        done.wait()

        if completed {
            return finish(.completed, tag: manifest.tag)
        }
        return finish(recordingActive() ? .paused : .retryableFailure, tag: manifest.tag)
    }

    private func finish(_ outcome: CallTranscriptionOutcome, tag: String) -> CallTranscriptionOutcome {
        setTranscribing(false)
        if outcome == .completed {
            log("[CallTranscription] Transcription complete for \(tag)")
            DispatchQueue.main.async { [weak self] in self?.onCompleted?(tag) }
        }
        return outcome
    }

    private func setTranscribing(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isTranscribing = value
            self?.onStateChanged?(value)
        }
    }
}
