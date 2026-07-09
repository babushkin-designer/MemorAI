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
        Ты делаешь выжимку из транскрипта рабочего звонка. Транскрипт диаризован по дорожкам: \
        "Я" — это Илья (владелец записи), "Собеседник" — все остальные участники звонка \
        (их может быть несколько, они записаны одной дорожкой). \
        Определи реальные имена участников из контекста — люди обращаются друг к другу по имени, \
        представляются; используй эти имена вместо "Собеседник" везде, где атрибуция ясна. \
        Если непонятно, кто именно из участников говорит, — пиши нейтрально, не угадывай. \
        Пиши по-русски, кратко и по делу, в Markdown. Не выдумывай ничего, чего нет в транскрипте; \
        если что-то неясно — пометь как открытый вопрос.
        """
        let user = """
        Сделай саммари звонка в таком формате:

        ## Участники
        (кто был на звонке — имена/роли, насколько можно понять из контекста)

        ## О чём звонок
        (2-4 предложения)

        ## Ключевые решения
        (маркированный список; если решений не было — "—")

        ## Задачи
        (список вида "- [имя] что сделать — срок, если назван")

        ## Открытые вопросы
        (список; если нет — "—")

        Транскрипт:
        \(truncated(transcript))
        """
        return (system, user)
    }

    static func followupPrompt(transcript: String, otherName: String?) -> (system: String, user: String) {
        let participants = (otherName ?? "").trimmingCharacters(in: .whitespaces)
        let naming = participants.isEmpty
            ? """
            Участники со стороны клиента не указаны — определи их имена и роли сам из контекста \
            транскрипта (обращения по имени, представления). Если имя определить нельзя — \
            обращайся нейтрально, без выдуманных имён.
            """
            : """
            Участники со стороны клиента (подсказка от Ильи, приоритетнее твоих догадок из \
            контекста): \(participants). Дополни ролями/именами из транскрипта, если там есть ещё люди.
            """
        let system = """
        Ты помогаешь Илье (фрилансер, дизайн/продукт) написать follow-up сообщение клиенту \
        после созвона. Транскрипт диаризован по дорожкам: "Я" — Илья, "Собеседник" — все \
        остальные участники звонка (их может быть несколько, записаны одной дорожкой). \(naming) \
        Пиши по-русски от первого лица (от Ильи), дружелюбно и профессионально, без воды. \
        Задачи и договорённости адресуй конкретным людям по именам, где это ясно. \
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

    /// Titles need only the shape of the call — the head of the transcript is
    /// enough and keeps every title generation at ~1k tokens.
    static let titleTranscriptChars = 4000

    static func titlePrompt(transcript: String) -> (system: String, user: String) {
        let system = """
        Ты придумываешь короткое название для записи рабочего звонка. Транскрипт диаризован: \
        "Я" — Илья, "Собеседник" — остальные участники (имена ищи в контексте). \
        Ответь ОДНОЙ строкой: 3-6 слов, о чём звонок и с кем (если имя понятно из контекста). \
        Без кавычек, без точки в конце, без пояснений. Примеры формата: \
        "Правки лендинга с Егором", "Синк по дизайн-системе", "Созвон с клиентом: логотип".
        """
        let user = """
        Назови этот звонок.

        Начало транскрипта:
        \(String(transcript.prefix(titleTranscriptChars)))
        """
        return (system, user)
    }

    /// LLM output → safe one-line menu title.
    static func sanitizeTitle(_ raw: String) -> String {
        var line = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»'.“” "))
        if line.count > 60 { line = String(line.prefix(59)) + "…" }
        return line
    }

    /// Generate `call_<tag>_title.txt` for a session. No-op when a title
    /// already exists or the transcript is missing. Safe to call repeatedly.
    @discardableResult
    static func generateTitle(for session: CallSession) -> Bool {
        guard session.title == nil,
              let transcriptURL = session.transcriptURL,
              let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return false
        }
        let prompt = titlePrompt(transcript: transcript)
        switch LLMClient.shared.complete(system: prompt.system, user: prompt.user) {
        case .failure(let error):
            log("[CallLLM] ⚠️ Title generation failed for \(session.tag): \(error.localizedDescription)")
            return false
        case .success(let raw):
            let title = sanitizeTitle(raw)
            guard !title.isEmpty else { return false }
            let url = transcriptURL.deletingLastPathComponent()
                .appendingPathComponent("call_\(session.tag)_title.txt")
            try? (title + "\n").write(to: url, atomically: true, encoding: .utf8)
            log("[CallLLM] 🏷 \(session.tag): \(title)")
            return true
        }
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
