import Foundation

/// Serializes all call-related LLM work and owns its rate-limit policy.
/// AppKit callers receive completions on the main queue and only render UI.
final class CallLLMService {
    static let shared = CallLLMService()
    static let historyLimit = 100

    private let queue = DispatchQueue(label: "com.local.memorai.llm", qos: .utility)
    private let lock = UnfairLock()
    private var _isBusy = false

    var onBusyChanged: ((Bool) -> Void)?
    var isBusy: Bool { lock.withLock { _isBusy } }

    func session(tag: String, outputPath: String) -> CallSession? {
        CallHistory.recentSessions(outputPath: outputPath, limit: Self.historyLimit)
            .first { $0.tag == tag }
    }

    func autoTitle(tag: String, outputPath: String) {
        queue.async {
            guard let session = self.session(tag: tag, outputPath: outputPath),
                  session.transcriptURL != nil,
                  session.title == nil else { return }
            CallLLM.generateTitle(for: session)
        }
    }

    @discardableResult
    func generateMissingTitles(outputPath: String) -> Bool {
        guard beginBusyJob() else { return false }
        queue.async {
            let untitled = CallHistory.recentSessions(outputPath: outputPath, limit: Self.historyLimit)
                .filter { $0.transcriptURL != nil && $0.title == nil }
            var completed = 0
            for (index, session) in untitled.enumerated() {
                // Bluesminds free tier throttles bursts aggressively.
                if index > 0 { Thread.sleep(forTimeInterval: 12) }
                if CallLLM.generateTitle(for: session) { completed += 1 }
            }
            log("[CallLLM] Title backfill: \(completed)/\(untitled.count) generated")
            self.endBusyJob()
        }
        return true
    }

    @discardableResult
    func generate(_ kind: CallLLM.Kind, for session: CallSession,
                  completion: @escaping (Result<URL, LLMError>) -> Void) -> Bool {
        guard beginBusyJob() else { return false }
        queue.async {
            let result = CallLLM.generate(kind, for: session)
            self.endBusyJob {
                completion(result)
            }
        }
        return true
    }

    private func beginBusyJob() -> Bool {
        let started = lock.withLock { () -> Bool in
            guard !_isBusy else { return false }
            _isBusy = true
            return true
        }
        if started { notifyBusyChanged(true) }
        return started
    }

    private func endBusyJob(completion: (() -> Void)? = nil) {
        lock.withLock { _isBusy = false }
        DispatchQueue.main.async { [weak self] in
            self?.onBusyChanged?(false)
            completion?()
        }
    }

    private func notifyBusyChanged(_ busy: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onBusyChanged?(busy) }
    }
}
