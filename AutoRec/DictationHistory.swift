import Foundation

struct DictationEntry {
    let timestamp: Date
    let text: String
}

/// Persistent history of dictations so nothing is ever lost when the paste
/// target isn't focused (the SuperWhisper behaviour the user relied on):
/// every recognized dictation is appended to `dictation.jsonl` and kept in a
/// small in-memory buffer for the menu, from where it can be re-copied.
final class DictationHistory {
    private let storageURL: URL
    private(set) var recentEntries: [DictationEntry] = []
    private let maxEntries = 50
    private let queue = DispatchQueue(label: "com.local.memorai.dictation-history")

    init(outputPath: String) {
        self.storageURL = URL(fileURLWithPath: outputPath).appendingPathComponent("dictation.jsonl")
        load()
    }

    /// Record a dictation (called on the work queue after recognition).
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = DictationEntry(timestamp: Date(), text: trimmed)

        queue.sync {
            recentEntries.insert(entry, at: 0)
            if recentEntries.count > maxEntries { recentEntries.removeLast() }
        }

        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
            "text": trimmed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: storageURL.path) {
            if let fh = try? FileHandle(forWritingTo: storageURL) {
                fh.seekToEndOfFile()
                fh.write(lineData)
                fh.closeFile()
            }
        } else {
            try? lineData.write(to: storageURL)
        }
    }

    private func load() {
        guard let content = try? String(contentsOf: storageURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var loaded: [DictationEntry] = []
        for line in lines.suffix(maxEntries).reversed() {
            guard let data = line.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = d["text"] as? String else { continue }
            let ts = ISO8601DateFormatter().date(from: d["timestamp"] as? String ?? "") ?? Date()
            loaded.append(DictationEntry(timestamp: ts, text: text))
        }
        recentEntries = loaded
    }
}
