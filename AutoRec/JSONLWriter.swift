import Foundation

/// Appends one JSON record per line. Two files in this app are written this
/// way: the clipboard log and the per-day screen index.
final class JSONLWriter {
    static let shared = JSONLWriter()
    private let queue = DispatchQueue(label: "com.memorai.jsonl-writer")

    private init() {}

    /// Fire-and-forget append, for callers with nothing useful to do about a
    /// failure. Failures are logged rather than swallowed, so a full disk shows
    /// up as something other than a gap in the record.
    func append(_ record: [String: Any], to fileURL: URL) {
        queue.async {
            do {
                try Self.appendNow(record, to: fileURL)
            } catch {
                log("[JSONL] ❌ Could not append to \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous append that throws. Callers that treat "written" as the
    /// moment a capture is kept — ClipboardMonitor advances its change count
    /// off this — need to know when it did not happen.
    static func appendNow(_ record: [String: Any], to fileURL: URL) throws {
        // `data(withJSONObject:)` RAISES on a value it cannot encode rather
        // than throwing, and an ObjC exception unwinding into Swift aborts the
        // process. Everything written here is a String today; a crash is still
        // not the right answer if that ever stops being true.
        guard JSONSerialization.isValidJSONObject(record) else {
            throw NSError(domain: "MemorAI.JSONL", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "record is not encodable as JSON"])
        }
        var data = try JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
