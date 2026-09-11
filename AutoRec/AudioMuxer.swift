import Foundation

/// Replaces the video-only screen.mp4 in-place with a copy that has both mic and
/// system audio mixed in. Originals (mic.m4a, system.m4a) are left untouched —
/// Transcriber consumes them after, and they're useful for re-mixing later.
///
/// The three files start at different wall-clock moments (SCStream comes up
/// before the mic engine; the video session opens on the first captured frame),
/// so each audio track is shifted onto the video's timeline before mixing.
/// Without this, audio that reaches both tracks (speaker leak into the mic on
/// headphone-less calls) played twice ~130 ms apart — an audible echo.
class AudioMuxer {
    static let shared = AudioMuxer()

    /// What the recorders capture at, and what the muxed video keeps.
    static let outputSampleRate = 48000

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "ffmpeg"
    }()

    private let queue = DispatchQueue(label: "com.local.memorai.audiomux", qos: .utility)

    /// Track start times are host-clock seconds (mic: first tap buffer,
    /// system/video: first sample PTS); nil means unknown → track is not shifted.
    func muxScreenWithAudio(screenURL: URL, micURL: URL?, systemURL: URL?,
                            micStartSeconds: Double? = nil,
                            systemStartSeconds: Double? = nil,
                            videoStartSeconds: Double? = nil,
                            completion: (() -> Void)? = nil) {
        queue.async { [self] in
            _ = mux(screenURL: screenURL, micURL: micURL, systemURL: systemURL,
                    micStartSeconds: micStartSeconds, systemStartSeconds: systemStartSeconds,
                    videoStartSeconds: videoStartSeconds)
            completion?()
        }
    }

    /// Same job, run on the caller's thread. The post-processing pipeline is
    /// already on a background queue and needs each stage's verdict before it
    /// records progress, so it calls this directly. Returns false when the
    /// video was left as it was.
    @discardableResult
    func muxNow(screenURL: URL, micURL: URL?, systemURL: URL?,
                micStartSeconds: Double?, systemStartSeconds: Double?,
                videoStartSeconds: Double?) -> Bool {
        mux(screenURL: screenURL, micURL: micURL, systemURL: systemURL,
            micStartSeconds: micStartSeconds, systemStartSeconds: systemStartSeconds,
            videoStartSeconds: videoStartSeconds)
    }

    /// Per-track shift (seconds) onto the video timeline. Positive = the track
    /// started later than the reference and gets delayed; negative = it started
    /// earlier and its head gets trimmed. Falls back to the earliest audio
    /// track as reference when the video start is unknown.
    static func computeOffsets(micStart: Double?, systemStart: Double?,
                               videoStart: Double?) -> (mic: Double, system: Double) {
        let audioStarts = [micStart, systemStart].compactMap { $0 }
        guard let reference = videoStart ?? audioStarts.min() else { return (0, 0) }
        func offset(_ start: Double?) -> Double {
            guard let start = start else { return 0 }
            let off = start - reference
            // A huge offset means a clock/PTS anomaly — better to mix unshifted
            // than to delay or silence a big chunk of the track.
            return abs(off) <= 10 ? off : 0
        }
        return (offset(micStart), offset(systemStart))
    }

    /// Pure ffmpeg argument builder. Input order: 0 = video, then mic, then
    /// system (whichever exist). Caller guarantees at least one audio path.
    static func buildMuxArgs(screenPath: String, micPath: String?, sysPath: String?,
                             micOffset: Double, sysOffset: Double,
                             outPath: String) -> [String] {
        var inputs: [(path: String, offset: Double)] = []
        if let micPath = micPath { inputs.append((micPath, micOffset)) }
        if let sysPath = sysPath { inputs.append((sysPath, sysOffset)) }

        // -v error keeps stderr bounded — it's read only after exit, and a
        // chatty ffmpeg could otherwise fill the pipe buffer and deadlock.
        var args: [String] = ["-y", "-v", "error", "-i", screenPath]
        for input in inputs { args.append(contentsOf: ["-i", input.path]) }

        func src(_ i: Int) -> String { "[\(i + 1):a]" }

        func shiftOps(_ offset: Double) -> String? {
            if offset > 0.001 {
                return "adelay=\(Int((offset * 1000).rounded())):all=1"
            }
            if offset < -0.001 {
                return String(format: "atrim=start=%.3f,asetpts=PTS-STARTPTS", -offset)
            }
            return nil
        }

        var filterParts: [String] = []
        var pads: [String] = []
        for (i, input) in inputs.enumerated() {
            // EVERY input is resampled BEFORE it reaches amix, which otherwise
            // adopts the rate of its first input: the echo-cancelled mic is
            // 16 kHz (the model's rate), and on the 2026-08-11 call — the first
            // one where the cleaned track was actually used — it dragged the
            // far side's 48 kHz voice down with it. Doing this on the output
            // instead is not the same fix and was measured not to work: the mix
            // is already band-limited by then, so upsampling it back only
            // relabels the file (8-12 kHz came out 23 dB down, 12-20 kHz 50 dB).
            var ops = ["aresample=\(outputSampleRate)"]
            if let shift = shiftOps(input.offset) { ops.append(shift) }
            filterParts.append("\(src(i))\(ops.joined(separator: ","))[t\(i)]")
            pads.append("[t\(i)]")
        }

        let audioMap: String
        if pads.count == 2 {
            filterParts.append("\(pads[0])\(pads[1])amix=inputs=2:duration=longest:dropout_transition=0[a]")
            audioMap = "[a]"
        } else {
            audioMap = pads[0]
        }

        args.append(contentsOf: ["-filter_complex", filterParts.joined(separator: ";")])
        args.append(contentsOf: [
            "-map", "0:v",
            "-map", audioMap,
            "-c:v", "copy",
            "-c:a", "aac",
            // Belt and braces: the graph above already delivers this rate, and
            // this keeps the container honest whatever shape the graph takes.
            "-ar", "\(outputSampleRate)",
            "-b:a", "128k",
            outPath,
        ])
        return args
    }

    private func mux(screenURL: URL, micURL: URL?, systemURL: URL?,
                     micStartSeconds: Double?, systemStartSeconds: Double?,
                     videoStartSeconds: Double?) -> Bool {
        guard FileManager.default.fileExists(atPath: screenURL.path) else {
            log("[AudioMuxer] Screen file missing — skipping")
            return false
        }

        let micExists = micURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let sysExists = systemURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard micExists || sysExists else {
            log("[AudioMuxer] No audio sources — skipping screen mux")
            return false
        }

        let tempURL = screenURL.deletingPathExtension().appendingPathExtension("muxing.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        let offsets = Self.computeOffsets(micStart: micExists ? micStartSeconds : nil,
                                          systemStart: sysExists ? systemStartSeconds : nil,
                                          videoStart: videoStartSeconds)
        let args = Self.buildMuxArgs(screenPath: screenURL.path,
                                     micPath: micExists ? micURL!.path : nil,
                                     sysPath: sysExists ? systemURL!.path : nil,
                                     micOffset: offsets.mic,
                                     sysOffset: offsets.system,
                                     outPath: tempURL.path)

        let sources = [micExists ? "mic" : nil, sysExists ? "system" : nil]
            .compactMap { $0 }.joined(separator: "+")
        log(String(format: "[AudioMuxer] Muxing %@ → %@ (offsets mic %+.3fs, system %+.3fs)",
                   sources, screenURL.lastPathComponent, offsets.mic, offsets.system))

        // Via ProcessRunner: reading stderr only after waitUntilExit() deadlocks
        // whenever ffmpeg fills the 64 KB pipe buffer, which it does on a
        // malformed input — exactly when the error text is worth having.
        let result = ProcessRunner.run(ffmpegPath, args: args, timeout: 1800, role: .postProcessing)
        guard result.exitCode == 0 else {
            let why = result.wasCancelled ? "not started (a recording began)"
                : result.timedOut ? "timed out" : "exit \(result.exitCode)"
            log("[AudioMuxer] ❌ ffmpeg failed (\(why)): \(result.stderrTail)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(screenURL, withItemAt: tempURL)
            log("[AudioMuxer] ✅ Audio muxed into \(screenURL.lastPathComponent)")
            return true
        } catch {
            log("[AudioMuxer] ❌ Replace failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
