import Foundation

/// One recorded call session, assembled from the `call_<tag>_*` files that
/// share a timestamp tag in the output directory. Any of the artifacts may be
/// absent (e.g. transcript/summary are produced asynchronously after the call,
/// video only when screen recording is on).
struct CallSession {
    let tag: String          // "2026-07-09_16-24-44"
    let date: Date
    var videoURL: URL?       // call_<tag>_screen.mp4 (mic+system muxed in)
    var micURL: URL?         // call_<tag>_mic.m4a
    var systemURL: URL?      // call_<tag>_system.m4a
    var transcriptURL: URL?  // call_<tag>_transcript.txt
    var summaryURL: URL?     // call_<tag>_summary.md
    var followupURL: URL?    // call_<tag>_followup.md

    var hasAudio: Bool { micURL != nil || systemURL != nil }
}

/// Read-only scanner over the output directory that groups `call_*` files into
/// sessions for the menu. Nothing is cached — the folder is re-read on demand
/// so freshly-finished transcripts/summaries show up without a restart.
enum CallHistory {

    /// Most recent sessions, newest first, capped at `limit`.
    static func recentSessions(outputPath: String, limit: Int = 20) -> [CallSession] {
        let dir = URL(fileURLWithPath: outputPath)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: outputPath) else { return [] }

        var byTag: [String: CallSession] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        for name in names {
            guard name.hasPrefix("call_") else { continue }
            guard let (tag, role) = Self.parse(filename: name) else { continue }

            var session = byTag[tag] ?? CallSession(tag: tag, date: fmt.date(from: tag) ?? Date.distantPast)
            let url = dir.appendingPathComponent(name)
            switch role {
            case "screen":     session.videoURL = url
            case "mic":        session.micURL = url
            case "system":     session.systemURL = url
            case "transcript": session.transcriptURL = url
            case "summary":    session.summaryURL = url
            case "followup":   session.followupURL = url
            default:           break
            }
            byTag[tag] = session
        }

        return byTag.values
            .sorted { $0.tag > $1.tag }   // tags are lexicographically sortable by time
            .prefix(limit)
            .map { $0 }
    }

    /// Split "call_2026-07-09_16-24-44_transcript.txt" → (tag, role).
    /// Returns nil for names that don't fit the pattern.
    static func parse(filename: String) -> (tag: String, role: String)? {
        guard filename.hasPrefix("call_") else { return nil }
        let stem = (filename as NSString).deletingPathExtension  // drop .m4a/.mp4/.txt/.md
        let body = String(stem.dropFirst("call_".count))         // "<tag>_<role>"
        guard let sep = body.range(of: "_", options: .backwards) else { return nil }
        let tag = String(body[..<sep.lowerBound])
        let role = String(body[sep.upperBound...])
        guard !tag.isEmpty, !role.isEmpty else { return nil }
        return (tag, role)
    }
}
