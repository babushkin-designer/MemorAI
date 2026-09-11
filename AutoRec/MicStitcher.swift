import Foundation

/// Joins the mic segments a call may have been split into back into one
/// `call_<tag>_mic.m4a`, so everything downstream (AudioMuxer, Transcriber,
/// CallHistory) keeps seeing exactly one mic file.
///
/// Why segments exist: an AVAudioFile's format is fixed when it is opened, but
/// the input device can change mid-call (AirPods connect → 16 kHz/2ch becomes
/// 48 kHz/7ch). Writing the new format into the old file fails on every buffer,
/// which used to silence the mic for the rest of the call. MicRecorder now ends
/// the segment and opens a new one in the new format instead.
///
/// The engine is down for a second or two across a device switch, so the
/// segments do not butt up against each other. That hole is filled with
/// generated silence — concatenating without it would pull every later word
/// earlier in the timeline and drift the mic track out of sync with the system
/// track, which the speaker-labeled transcript interleaves by timestamp.
class MicStitcher {
    static let shared = MicStitcher()

    /// Everything is resampled to one format before concat: segments differ in
    /// rate and channel count by definition, and concat demands they match.
    /// Mono 48 kHz is what the consumers want anyway (whisper downsamples to
    /// 16 kHz mono; the muxer mixes into the video's stereo track).
    static let canonicalSampleRate = 48000
    static let canonicalChannels = "mono"

    /// Below this a "gap" is just buffer jitter, not a real hole.
    static let minGapSeconds: Double = 0.05
    /// A device switch costs a second or two. Anything far beyond that means a
    /// paused recording or a host-clock anomaly — pad a sane amount instead of
    /// injecting minutes of silence.
    static let maxGapSeconds: Double = 30.0

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "ffmpeg"
    }()

    /// Silence (seconds) to insert before each segment; the first is always 0.
    /// A segment whose start or predecessor's start is unknown gets 0 — better
    /// a slightly short track than a wrong amount of padding.
    static func gaps(for segments: [(firstHost: Double?, duration: Double)]) -> [Double] {
        guard !segments.isEmpty else { return [] }
        var result: [Double] = [0]
        for i in 1..<segments.count {
            guard let prevStart = segments[i - 1].firstHost,
                  let start = segments[i].firstHost else {
                result.append(0)
                continue
            }
            let gap = start - (prevStart + segments[i - 1].duration)
            // NaN/inf would survive the comparisons below and reach ffmpeg as
            // `atrim=end=nan`, failing the whole stitch.
            guard gap.isFinite else {
                result.append(0)
                continue
            }
            if gap < minGapSeconds {
                result.append(0)          // overlap or jitter
            } else {
                result.append(min(gap, maxGapSeconds))
            }
        }
        return result
    }

    /// Pure ffmpeg argument builder. `gaps[i]` is silence inserted before
    /// segment `i`. A single segment is still a valid job — it is transcoded
    /// into the canonical format, which is how an LPCM segment (a >2ch input
    /// AAC cannot encode) becomes the final m4a. Returns nil only for input it
    /// cannot describe.
    static func buildConcatArgs(paths: [String], gaps: [Double], outPath: String) -> [String]? {
        guard !paths.isEmpty, gaps.count == paths.count else { return nil }

        // -v error keeps stderr bounded — it is read only after exit, and a
        // chatty ffmpeg could otherwise fill the pipe buffer and deadlock.
        var args: [String] = ["-y", "-v", "error"]
        for path in paths { args.append(contentsOf: ["-i", path]) }

        let rate = canonicalSampleRate
        let normalize = "aresample=\(rate),aformat=sample_fmts=fltp:channel_layouts=\(canonicalChannels)"

        var filterParts: [String] = []
        var pads: [String] = []
        for (i, gap) in gaps.enumerated() {
            if i > 0, gap > 0 {
                // anullsrc is infinite; atrim cuts it to the hole's length.
                filterParts.append(String(format:
                    "anullsrc=r=%d:cl=%@,atrim=end=%.3f,asetpts=PTS-STARTPTS[g%d]",
                    rate, canonicalChannels, gap, i))
                pads.append("[g\(i)]")
            }
            filterParts.append("[\(i):a]\(normalize)[a\(i)]")
            pads.append("[a\(i)]")
        }
        // One part needs no concat — it is already the whole track.
        let outLabel: String
        if pads.count == 1 {
            outLabel = pads[0]
        } else {
            filterParts.append("\(pads.joined())concat=n=\(pads.count):v=0:a=1[out]")
            outLabel = "[out]"
        }

        args.append(contentsOf: [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", outLabel,
            "-c:a", "aac",
            "-b:a", "64k",
            outPath,
        ])
        return args
    }

    /// Segments with audio in them that are still on disk.
    private func usableSegments(_ segments: [MicRecorder.Segment]) -> [MicRecorder.Segment] {
        segments.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// True when a lone segment is already the finished track in the output
    /// format and only needs its canonical name — no transcode, no ffmpeg.
    /// The quit path checks this: a rename is bounded work, a transcode is not.
    func canPublishByRename(segments: [MicRecorder.Segment], outputURL: URL) -> Bool {
        Self.isReadyToPublish(usableSegments(segments), outputURL: outputURL)
    }

    static func isReadyToPublish(_ segments: [MicRecorder.Segment], outputURL: URL) -> Bool {
        segments.count == 1
            && segments[0].url != outputURL
            && segments[0].url.pathExtension.lowercased() == outputURL.pathExtension.lowercased()
    }

    /// Publishes `outputURL` from `segments`. Returns true when `outputURL`
    /// holds the whole mic track afterwards. On failure nothing is published:
    /// the segments stay on disk under their part names, and the canonical mic
    /// file stays absent rather than holding a fraction of the call.
    @discardableResult
    func stitch(segments: [MicRecorder.Segment], outputURL: URL) -> Bool {
        let usable = usableSegments(segments)
        guard !usable.isEmpty else { return false }
        // A lone segment already sitting at the destination is the whole track.
        guard usable.count > 1 || usable[0].url != outputURL else { return true }

        // The common case — one uninterrupted segment in the output format —
        // is a rename. Running it through ffmpeg would re-encode every call for
        // nothing and add a failure mode to the path that publishes the track.
        if Self.isReadyToPublish(usable, outputURL: outputURL) {
            do {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.moveItem(at: usable[0].url, to: outputURL)
                log("[MicStitcher] Mic track published as \(outputURL.lastPathComponent)")
                return true
            } catch {
                log("[MicStitcher] ❌ Could not publish \(usable[0].url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        let gaps = Self.gaps(for: usable.map { ($0.firstBufferHostSeconds, $0.duration) })
        let tempURL = outputURL.deletingPathExtension().appendingPathExtension("stitching.m4a")
        try? FileManager.default.removeItem(at: tempURL)

        guard let args = Self.buildConcatArgs(paths: usable.map { $0.url.path },
                                              gaps: gaps,
                                              outPath: tempURL.path) else { return false }

        let padding = gaps.reduce(0, +)
        if usable.count > 1 {
            log(String(format: "[MicStitcher] Joining %d mic segments (%.1fs silence bridging device switches) → %@",
                       usable.count, padding, outputURL.lastPathComponent))
        } else {
            log("[MicStitcher] Converting \(usable[0].url.lastPathComponent) → \(outputURL.lastPathComponent)")
        }

        // This runs before the stop completion, which on quit is what lets the
        // process exit — so it needs a deadline, not an open-ended wait.
        let result = ProcessRunner.run(ffmpegPath, args: args, timeout: 900, role: .postProcessing)
        guard result.exitCode == 0 else {
            let why = result.wasCancelled ? "not started (a recording began)"
                : result.timedOut ? "timed out" : "exit \(result.exitCode)"
            log("[MicStitcher] ❌ ffmpeg failed (\(why)): \(result.stderrTail)")
            log("[MicStitcher] Segments kept on disk for recovery: \(usable.map { $0.url.lastPathComponent }.joined(separator: ", "))")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        do {
            // replaceItemAt needs something to replace; with an LPCM-only call
            // the destination does not exist yet.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            log("[MicStitcher] ❌ Replace failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        // Only now that the finished track is in place are the parts redundant.
        for segment in usable where segment.url != outputURL {
            try? FileManager.default.removeItem(at: segment.url)
        }
        log("[MicStitcher] ✅ Mic track rejoined into \(outputURL.lastPathComponent)")
        return true
    }
}
