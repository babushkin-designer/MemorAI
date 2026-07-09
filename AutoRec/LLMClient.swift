import Foundation

enum LLMError: Error, LocalizedError {
    case noAPIKey(String)          // keychain service name
    case quotaExhausted            // 429 insufficient_quota — STOP, never retry
    case http(Int, String)
    case transport(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let service):
            return "API key not found in Keychain (service \"\(service)\")."
        case .quotaExhausted:
            return "LLM tokens exhausted (insufficient_quota) — resume only after billing/usage action. Not retrying."
        case .http(let code, let body):
            return "LLM HTTP \(code): \(body.prefix(200))"
        case .transport(let message):
            return "LLM network error: \(message)"
        case .badResponse:
            return "LLM returned an unparseable response."
        }
    }
}

struct LLMProvider {
    let id: String
    let endpoint: String
    let keychainService: String

    static let bluesminds = LLMProvider(
        id: "bluesminds",
        endpoint: "https://api.bluesminds.com/v1/chat/completions",
        keychainService: "bluesminds-api-key"
    )
    static let openai = LLMProvider(
        id: "openai",
        endpoint: "https://api.openai.com/v1/chat/completions",
        keychainService: "openai-api-key"
    )

    static func named(_ id: String) -> LLMProvider {
        id == "openai" ? .openai : .bluesminds
    }
}

/// Minimal OpenAI-compatible chat-completions client for summary/follow-up.
///
/// Guardrails (plan 012): hard max_tokens cap on every request; token usage
/// from each response is logged; 429 insufficient_quota is terminal (no
/// retry) because past that point traffic bills real money. Bounded retry (2)
/// only for transport errors and 5xx.
class LLMClient {
    static let shared = LLMClient()

    private let maxOutputTokens = 4096
    private let requestTimeout: TimeInterval = 180
    private let maxAttempts = 2

    // MARK: - Pure helpers (unit-tested)

    static func requestBody(model: String, system: String, user: String, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
    }

    /// Extract assistant text; returns nil when the shape is wrong or empty.
    static func parseContent(_ data: Data) -> (text: String, tokensIn: Int, tokensOut: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let usage = obj["usage"] as? [String: Any]
        return (
            content,
            usage?["prompt_tokens"] as? Int ?? 0,
            usage?["completion_tokens"] as? Int ?? 0
        )
    }

    /// Map an error response; the insufficient_quota case must never be retried.
    static func errorKind(status: Int, data: Data) -> LLMError {
        let body = String(data: data, encoding: .utf8) ?? ""
        if status == 429 {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = obj["error"] as? [String: Any] {
                let code = String(describing: error["code"] ?? error["type"] ?? "").lowercased()
                if code.contains("insufficient_quota") { return .quotaExhausted }
            }
            if body.lowercased().contains("insufficient_quota") { return .quotaExhausted }
        }
        return .http(status, body)
    }

    static func isRetryable(_ error: LLMError) -> Bool {
        switch error {
        case .transport: return true
        case .http(let code, _): return code >= 500
        case .quotaExhausted, .noAPIKey, .badResponse: return false
        }
    }

    // MARK: - Call

    /// Synchronous — call from a background queue only.
    func complete(system: String, user: String) -> Result<String, LLMError> {
        let provider = LLMProvider.named(SettingsManager.shared.llmProvider)
        let model = SettingsManager.shared.llmModel
        guard let key = Keychain.read(service: provider.keychainService) else {
            return .failure(.noAPIKey(provider.keychainService))
        }

        var lastError: LLMError = .badResponse
        for attempt in 1...maxAttempts {
            let result = post(provider: provider, model: model, key: key, system: system, user: user)
            switch result {
            case .success(let text):
                return .success(text)
            case .failure(let error):
                lastError = error
                if !Self.isRetryable(error) { return .failure(error) }
                log("[LLM] Attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)) — \(attempt < maxAttempts ? "retrying" : "giving up")")
            }
        }
        return .failure(lastError)
    }

    private func post(provider: LLMProvider, model: String, key: String,
                      system: String, user: String) -> Result<String, LLMError> {
        guard let url = URL(string: provider.endpoint) else { return .failure(.badResponse) }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Self.requestBody(model: model, system: system, user: user, maxTokens: maxOutputTokens)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse)
        }
        request.httpBody = bodyData

        var outcome: Result<String, LLMError> = .failure(.transport("no response"))
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error = error {
                outcome = .failure(.transport(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                outcome = .failure(.transport("empty response"))
                return
            }
            guard http.statusCode == 200 else {
                outcome = .failure(Self.errorKind(status: http.statusCode, data: data))
                return
            }
            guard let parsed = Self.parseContent(data) else {
                outcome = .failure(.badResponse)
                return
            }
            log("[LLM] \(provider.id)/\(model): \(parsed.tokensIn) in / \(parsed.tokensOut) out tokens")
            outcome = .success(parsed.text)
        }.resume()
        _ = sema.wait(timeout: .now() + requestTimeout + 10)
        return outcome
    }
}
