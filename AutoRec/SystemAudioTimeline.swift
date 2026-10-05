import Foundation

/// AVAssetWriter's m4a audio track compacts PTS holes (verified by capture
/// probe). Record holes while capturing and restore them OFFLINE, before
/// transcription, echo cancellation or muxing. No encoding of pause silence
/// competes with the live call.
struct SystemAudioTimeline: Codable {
    struct Gap: Codable {
        let position: Double // Position in the compact file, before this hole.
        let seconds: Double
    }
    var gaps: [Gap] = []
    var capturedSeconds = 0.0
    private var firstHost: Double?
    private var paddedSeconds = 0.0
    private enum CodingKeys: String, CodingKey { case gaps, capturedSeconds }

    mutating func record(host: Double, duration: Double) {
        guard host.isFinite, duration.isFinite, duration > 0 else { return }
        if firstHost == nil { firstHost = host }
        let deficit = host - ((firstHost ?? host) + capturedSeconds + paddedSeconds)
        // Measure against accepted frames, not each buffer's timestamp: small
        // positive/negative boundary jitter must cancel rather than add silence.
        if deficit > max(duration, 0.005) {
            gaps.append(Gap(position: capturedSeconds, seconds: deficit))
            paddedSeconds += deficit
        }
        capturedSeconds += duration
    }

    func arguments(input: String, output: String) -> [String]? {
        guard capturedSeconds.isFinite, capturedSeconds > 0, !gaps.isEmpty else { return nil }
        var cursor = 0.0
        var filters: [String] = []
        var labels: [String] = []
        for (i, gap) in gaps.enumerated() {
            guard gap.position.isFinite, gap.seconds.isFinite, gap.seconds > 0,
                  gap.position > cursor, gap.position <= capturedSeconds else { return nil }
            filters.append(String(format: "[0:a]atrim=start=%.9f:end=%.9f,asetpts=PTS-STARTPTS[a%d]",
                                  cursor, gap.position, i))
            filters.append(String(format: "anullsrc=r=48000:cl=stereo,atrim=end=%.9f,asetpts=PTS-STARTPTS[g%d]",
                                  gap.seconds, i))
            labels += ["[a\(i)]", "[g\(i)]"]
            cursor = gap.position
        }
        let i = gaps.count
        filters.append(String(format: "[0:a]atrim=start=%.9f:end=%.9f,asetpts=PTS-STARTPTS[a%d]",
                              cursor, capturedSeconds, i))
        labels.append("[a\(i)]")
        filters.append("\(labels.joined())concat=n=\(labels.count):v=0:a=1[out]")
        return ["-y", "-v", "error", "-i", input, "-filter_complex", filters.joined(separator: ";"),
                "-map", "[out]", "-ar", "48000", "-ac", "2", "-c:a", "aac", "-b:a", "64k", output]
    }

    /// The compact original is immutable across retries. If the process dies
    /// after publication but before saving its stage, retry cannot pad twice.
    func restore(at url: URL) -> Bool {
        guard !gaps.isEmpty else { return true }
        let compact = url.deletingPathExtension().appendingPathExtension("compact.m4a")
        let copy = url.deletingPathExtension().appendingPathExtension("compact.tmp")
        let work = url.deletingPathExtension().appendingPathExtension("timeline.m4a")
        let script = url.deletingPathExtension().appendingPathExtension("timeline.filter.txt")
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: script)
        }
        do {
            if !FileManager.default.fileExists(atPath: compact.path) {
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                guard rename(copy.path, compact.path) == 0 else { return false }
            }
            guard var args = arguments(input: compact.path, output: work.path),
                  let graphIndex = args.firstIndex(of: "-filter_complex") else { return false }
            try args[graphIndex + 1].write(to: script, atomically: true, encoding: .utf8)
            args[graphIndex] = "-filter_complex_script"
            args[graphIndex + 1] = script.path
            let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
            let result = ProcessRunner.run(ffmpeg, args: args, timeout: 900, role: .postProcessing)
            guard result.exitCode == 0 else {
                try? FileManager.default.removeItem(at: work)
                log("[SystemAudioTimeline] Restoration deferred/failed: \(result.stderrTail)")
                return false
            }
            guard rename(work.path, url.path) == 0 else {
                log("[SystemAudioTimeline] Could not publish restored track")
                return false
            }
            return true
        } catch {
            log("[SystemAudioTimeline] Compact source retained: \(error.localizedDescription)")
            return false
        }
    }
}
