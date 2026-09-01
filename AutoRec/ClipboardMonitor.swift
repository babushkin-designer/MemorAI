import AppKit
import Foundation
import ObjCTry

struct ClipboardEntry {
    let timestamp: Date
    let appName: String
    let bundleId: String
    let type: String  // text, image, url, file, other
    let content: String
}

class ClipboardMonitor {
    /// Only ever advanced once the entry it stands for is on disk — or once we
    /// have decided on purpose not to keep it. Advancing it first, as this used
    /// to, turned a failed append into a copy that never existed.
    private var lastChangeCount: Int = 0
    /// The change count whose append last failed, so a disk that stays full
    /// does not write the same complaint into the log every poll.
    private var lastReportedFailure: Int = 0
    private var storageURL: URL?
    private let pasteboard = NSPasteboard.general

    /// In-memory buffer of recent entries for the menu
    private(set) var recentEntries: [ClipboardEntry] = []
    private let maxEntries = 100

    func start(storageURL: URL) {
        self.storageURL = storageURL
        lastChangeCount = pasteboard.changeCount
        loadRecentEntries()
    }

    /// Called periodically. Checks if clipboard changed and saves if so.
    func checkAndSave(excludedBundleIds: [String]) {
        guard let storage = storageURL else { return }
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }

        // Honor the de-facto standard privacy markers set by password managers
        // and clipboard tools: never persist concealed or transient contents.
        // http://nspasteboard.org
        let privacyMarkers: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        ]
        if let types = pasteboard.types, privacyMarkers.contains(where: types.contains) {
            log("[Clipboard] Skipped concealed/transient clipboard entry")
            lastChangeCount = current
            return
        }

        // Skip excluded apps
        let frontApp = NSWorkspace.shared.frontmostApplication
        if let bundleId = frontApp?.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            lastChangeCount = current
            return
        }

        let now = Date()
        let appName = frontApp?.localizedName ?? ""
        let bundleId = frontApp?.bundleIdentifier ?? ""

        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: now),
            "app_name": appName,
            "app_bundle_id": bundleId,
        ]

        var type = "other"
        var content = ""

        // Try multiple text types
        let pb = self.pasteboard
        let textTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .html]
        let text = textTypes.lazy.compactMap { pb.string(forType: $0) }.first { !$0.isEmpty }

        if let text = text {
            type = "text"
            content = text
        } else if let tiffData = pasteboard.data(forType: .tiff),
                  let image = NSImage(data: tiffData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let dayDir = storage.appendingPathComponent("screen").appendingPathComponent(dayString(now))
            try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let filename = "clipboard-\(timeString(now)).jpg"
            let imageURL = dayDir.appendingPathComponent(filename)
            if let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            type = "image"
            content = filename
        } else if let url = pasteboard.string(forType: .URL) {
            type = "url"
            content = url
        } else if let files = pasteboard.propertyList(forType: .fileURL) as? String {
            type = "file"
            content = files
        } else {
            let types = pasteboard.types?.map { $0.rawValue } ?? []
            content = types.joined(separator: ", ")
        }

        entry["type"] = type
        entry["content"] = content

        // Disk first. The in-memory buffer and the change count both stand for
        // "this copy is kept", and neither may say so before it is true.
        let logURL = storage.appendingPathComponent("clipboard.jsonl")
        do {
            try Self.append(entry, to: logURL)
        } catch {
            if lastReportedFailure != current {
                lastReportedFailure = current
                log("[Clipboard] ❌ Could not append to clipboard.jsonl: \(error.localizedDescription) — retrying")
            }
            return   // change count untouched: the next poll tries this copy again
        }
        lastChangeCount = current

        let clipEntry = ClipboardEntry(timestamp: now, appName: appName, bundleId: bundleId, type: type, content: content)
        recentEntries.insert(clipEntry, at: 0)
        if recentEntries.count > maxEntries {
            recentEntries.removeLast()
        }
    }

    /// Append one JSON record as a line. Throws so the caller can keep the
    /// entry pending instead of losing it.
    static func append(_ entry: [String: Any], to logURL: URL) throws {
        // JSONSerialization RAISES on a value it cannot encode instead of
        // throwing, and an ObjC exception unwinding into Swift aborts the
        // process. Everything put in here is a String today; a crash is still
        // not the right answer if that ever stops being true.
        var encoded: Data?
        var swiftError: Error?
        var raised: NSError?
        let completed = MEMRunCatchingExceptions({
            do { encoded = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) }
            catch { swiftError = error }
        }, &raised)
        if let swiftError = swiftError { throw swiftError }
        if !completed, let raised = raised { throw raised }
        guard var data = encoded else {
            throw NSError(domain: "MemorAI.Clipboard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "entry could not be encoded"])
        }
        data.append(0x0A)
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            try data.write(to: logURL)
            return
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Load recent entries from clipboard.jsonl
    func loadRecentEntries() {
        let storage = storageURL ?? URL(fileURLWithPath: SettingsManager.shared.outputPath)
        let logURL = storage.appendingPathComponent("clipboard.jsonl")

        guard let data = try? String(contentsOf: logURL, encoding: .utf8) else { return }

        let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
        let tail = Array(lines.suffix(maxEntries))

        var loaded: [ClipboardEntry] = []
        for line in tail.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            loaded.append(ClipboardEntry(
                timestamp: ISO8601DateFormatter().date(from: d["timestamp"] as? String ?? "") ?? Date(),
                appName: d["app_name"] as? String ?? "",
                bundleId: d["app_bundle_id"] as? String ?? "",
                type: d["type"] as? String ?? "",
                content: d["content"] as? String ?? ""
            ))
        }
        recentEntries = loaded
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        return f.string(from: date)
    }
}
