import AVFoundation
import Cocoa

/// Explicit CLI diagnostic, never started by the menu app. Uses temporary
/// files, a quiet local tone, and the normal recorders without changing defaults
/// or audio-device properties. Separates capture health from audible acceptance.
@MainActor
enum AudioCaptureProbe {
    static func run(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let tone = directory.appendingPathComponent("tone.caf")
        do {
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 10)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.025)
            }
            try file.write(from: buffer)
        }
        var results: [[String: Any]] = []
        for mode in ["playback", "mic", "system", "screen", "combined-pause"] {
            let audio = directory.appendingPathComponent("\(mode)-system.m4a")
            let video = mode == "screen" || mode == "combined-pause"
                ? directory.appendingPathComponent("\(mode)-screen.mp4") : nil
            let sys = mode == "playback" || mode == "mic" ? nil : SystemAudioRecorder(audioURL: audio, videoURL: video)
            let mic = mode == "mic" || mode == "combined-pause"
                ? MicRecorder(outputURL: directory.appendingPathComponent("\(mode)-mic.m4a")) : nil
            let playback = Process()
            playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playback.arguments = [tone.path]
            AudioGlitchMonitor.shared.start(context: "probe \(mode)")
            AudioGlitchMonitor.shared.snapshot("probe before \(mode)")
            do {
                try playback.run() // Separate process: SCStream excludes our own audio.
                if let sys { try await sys.start() }
                if let mic { try mic.start() }
                if mode == "combined-pause" {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    mic?.isPaused = true
                    sys?.isPaused = true
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    mic?.isPaused = false
                    sys?.isPaused = false
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } else { try await Task.sleep(nanoseconds: 5_000_000_000) }
                mic?.stop()
                await sys?.stop()
            } catch {
                mic?.stop()
                await sys?.stop()
                if playback.isRunning { playback.terminate() }
                AudioGlitchMonitor.shared.stop()
                throw error
            }
            if playback.isRunning { playback.terminate() }
            AudioGlitchMonitor.shared.snapshot("probe after \(mode)")
            AudioGlitchMonitor.shared.stop()
            var result: [String: Any] = ["mode": mode]
            if let mic {
                result["micFrames"] = mic.segments.reduce(Int64(0)) { $0 + $1.frameCount }
                result["micPartCount"] = mic.segments.count
                let gaps = MicStitcher.gaps(for: mic.segments.map { ($0.firstBufferHostSeconds, $0.duration) },
                                            preserve: mic.segments.map { $0.preservesGap })
                result["micTimelineSeconds"] = mic.segments.reduce(0) { $0 + $1.duration } + gaps.reduce(0, +)
            }
            if let sys {
                result["systemCompactSeconds"] = try await AVURLAsset(url: audio).load(.duration).seconds
                result["systemGapSeconds"] = sys.audioTimeline.gaps.reduce(0) { $0 + $1.seconds }
                guard sys.audioTimeline.restore(at: audio) else { throw RecordingError.writerFailed("system timeline restoration") }
                result["systemSeconds"] = try await AVURLAsset(url: audio).load(.duration).seconds
            }
            results.append(result)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
            // Give read-only monitor stop/start commands time to flush between cases.
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
