import Foundation

/// Generates the summary / follow-up sidecar files for a recorded call by
/// feeding the speaker-labeled transcript to the configured LLM.
/// Transcript labels are "Я" (the user, Илья) and "Собеседник" (far side);
/// the follow-up prompt substitutes the far side's real name so the output
/// never says "Персона 1/2".
enum CallLLM {

    /// Transcripts longer than this are truncated head+tail (very long calls);
    /// gpt-5.5 context is large, this is just a safety bound.
    static let maxTranscriptChars = 200_000

    // MARK: - Prompts (pure, unit-tested)

    static func summaryPrompt(transcript: String) -> (system: String, user: String) {
        let system = """
        Ты делаешь выжимку из транскрипта рабочего звонка. Транскрипт диаризован: \
        "Я" — это Илья (владелец записи), "Собеседник" — вторая сторона. \
        Пиши по-русски, кратко и по делу, в Markdown. Не выдумывай ничего, чего нет в транскрипте; \
        если что-то неясно — пометь как открытый вопрос.
        """
        let user = """
        Сделай саммари звонка в таком формате:

        ## О чём звонок
        (2-4 предложения)

        ## Ключевые решения
        (маркированный список; если решений не было — "—")

        ## Задачи
        (список вида "- [кто] что сделать — срок, если назван")

        ## Открытые вопросы
        (список; если нет — "—")

        Транскрипт:
        \(truncated(transcript))
        """
        return (system, user)
    }

    static func followupPrompt(transcript: String, otherName: String?) -> (system: String, user: String) {
        let name = (otherName ?? "").trimmingCharacters(in: .whitespaces)
        let naming = name.isEmpty
            ? "Имя собеседника неизвестно — обращайся без имени, нейтрально."
            : "Собеседника зовут \(name) — используй это имя."
        let system = """
        Ты помогаешь Илье (фрилансер, дизайн/продукт) написать follow-up сообщение клиенту \
        после созвона. Транскрипт диаризован: "Я" — Илья, "Собеседник" — клиент. \(naming) \
        Пиши по-русски от первого лица (от Ильи), дружелюбно и профессионально, без воды. \
        Никогда не используй метки "Я"/"Собеседник"/"Персона" в тексте сообщения. \
        Не выдумывай договорённостей, которых нет в транскрипте.
        """
        let user = """
        Напиши follow-up сообщение клиенту по итогам звонка. Структура:
        - короткое вступление (спасибо за созвон, 1 строка);
        - о чём договорились (список);
        - что делаю я и к какому сроку;
        - что нужно от клиента;
        - следующий шаг / следующий созвон, если обсуждали.

        Транскрипт:
        \(truncated(transcript))
        """
        return (system, user)
    }

    static func truncated(_ transcript: String) -> String {
        guard transcript.count > maxTranscriptChars else { return transcript }
        let half = maxTranscriptChars / 2
        let head = transcript.prefix(half)
        let tail = transcript.suffix(half)
        return head + "\n\n[…транскрипт сокращён…]\n\n" + tail
    }

    // MARK: - Generation

    enum Kind {
        case summary
        case followup(otherName: String?)

        var suffix: String {
            switch self {
            case .summary: return "summary"
            case .followup: return "followup"
            }
        }
    }

    /// Reads the session transcript, calls the LLM and writes the sidecar .md.
    /// Runs the network call synchronously — call from a background queue.
    static func generate(_ kind: Kind, for session: CallSession) -> Result<URL, LLMError> {
        guard let transcriptURL = session.transcriptURL,
              let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.badResponse)
        }

        let prompt: (system: String, user: String)
        switch kind {
        case .summary:
            prompt = summaryPrompt(transcript: transcript)
        case .followup(let otherName):
            prompt = followupPrompt(transcript: transcript, otherName: otherName)
        }

        log("[CallLLM] Generating \(kind.suffix) for \(session.tag) (\(transcript.count) chars)…")
        switch LLMClient.shared.complete(system: prompt.system, user: prompt.user) {
        case .failure(let error):
            log("[CallLLM] ❌ \(kind.suffix) failed: \(error.localizedDescription)")
            return .failure(error)
        case .success(let text):
            let outURL = transcriptURL.deletingLastPathComponent()
                .appendingPathComponent("call_\(session.tag)_\(kind.suffix).md")
            do {
                try text.write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                log("[CallLLM] ❌ Write failed: \(error.localizedDescription)")
                return .failure(.badResponse)
            }
            log("[CallLLM] ✅ Saved \(outURL.lastPathComponent)")
            return .success(outURL)
        }
    }
}
