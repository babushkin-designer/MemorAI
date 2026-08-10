import Foundation

/// Daily data hygiene, run in-process. A launchd LaunchAgent can't do this
/// job: TCC denies /bin/bash under launchd access to the protected folders
/// the data dir lives in (~/Downloads, ~/Documents), while the
/// app itself already reads and writes its own data dir all day.
///
/// Policy (mirrors tools/retention.sh, which remains for manual runs from a
/// terminal): delete screenshot images older than `retentionDays`, keep the
/// OCR text (index.jsonl) forever, prune day dirs that became fully empty,
/// and cap memorai.log.
class RetentionManager {
    static let shared = RetentionManager()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.local.memorai.retention", qos: .background)

    private let retentionDays = 14
    private let maxLogBytes: UInt64 = 10 * 1024 * 1024
    private let keepLogBytes: UInt64 = 5 * 1024 * 1024

    /// First pass a couple of minutes after launch (not during startup), then daily.
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 120, repeating: 24 * 60 * 60)
        t.setEventHandler { [weak self] in self?.run() }
        t.resume()
        timer = t
    }

    func run() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: SettingsManager.shared.outputPath)
        let screenDir = base.appendingPathComponent("screen")
        guard fm.fileExists(atPath: screenDir.path) else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let imageExts: Set<String> = ["jpg", "heif", "png"]
        var removed = 0

        if let en = fm.enumerator(at: screenDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en {
                guard imageExts.contains(url.pathExtension.lowercased()),
                      let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      mtime < cutoff else { continue }
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                } catch {}
            }
        }

        // Prune day dirs that became completely empty (index.jsonl-only dirs stay).
        if let days = try? fm.contentsOfDirectory(at: screenDir, includingPropertiesForKeys: nil) {
            for day in days {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: day.path, isDirectory: &isDir), isDir.boolValue,
                      let contents = try? fm.contentsOfDirectory(atPath: day.path), contents.isEmpty else { continue }
                try? fm.removeItem(at: day)
            }
        }

        log("[Retention] kept text, removed \(removed) images older than \(retentionDays)d")
        capLog(at: base.appendingPathComponent("memorai.log"))
    }

    /// Truncate the log to its tail IN PLACE (same inode) — the Logger keeps
    /// an open append handle; replacing the file would strand its writes in
    /// the old inode. The handle's stale offset leaves one sparse gap after
    /// truncation, which is harmless.
    private func capLog(at url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > maxLogBytes else { return }
        guard let read = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? read.close() }
        guard (try? read.seek(toOffset: size - keepLogBytes)) != nil,
              let tail = try? read.readToEnd() else { return }
        guard let write = try? FileHandle(forWritingTo: url) else { return }
        defer { try? write.close() }
        try? write.truncate(atOffset: 0)
        try? write.write(contentsOf: tail)
        log("[Retention] truncated memorai.log to last \(keepLogBytes) bytes")
    }
}
