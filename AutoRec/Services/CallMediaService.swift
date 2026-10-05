import Foundation

/// Publishes and enhances the recorded media belonging to one call.
/// The pipeline scheduler decides when to run these idempotent operations;
/// this service owns how each media stage is performed.
final class CallMediaService {
    static let shared = CallMediaService()

    static func orphanMicParts(names: [String], tag: String) -> [String] {
        let prefix = "call_\(tag)_mic.part"
        return names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix(prefix) else { return nil }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: "."),
                      let index = Int(rest[..<dot]) else { return nil }
                return (index, name)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    func restoreSystemTimeline(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard manifest.stages.systemTimelineRestored == false else { return }
        guard let timeline = manifest.systemAudioTimeline,
              let url = manifest.resolve(manifest.systemFile, in: dir) else { return }
        if timeline.restore(at: url) {
            manifest.stages.systemTimelineRestored = true
            manifest.save(in: dir)
            // Keep the immutable source until the whole session completes:
            // cancellation can roll this stage back after publication.
        }
    }

    func discardCompactSystemTrack(_ manifest: CallSessionManifest, in dir: URL) {
        guard let url = manifest.resolve(manifest.systemFile, in: dir) else { return }
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("compact.m4a"))
    }

    func publishMicTrack(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.micPublished else { return }
        adoptOrphanParts(&manifest, in: dir)
        guard let micURL = manifest.resolve(manifest.micFile, in: dir) else {
            manifest.stages.micPublished = true
            return
        }
        let segments = manifest.micSegments(in: dir)
        guard !segments.isEmpty else {
            manifest.stages.micPublished = true
            return
        }

        if MicStitcher.shared.stitch(segments: segments, outputURL: micURL) {
            manifest.stages.micPublished = true
            manifest.save(in: dir)
        } else {
            let parts = segments.map { $0.url.lastPathComponent }.joined(separator: ", ")
            log("[CallMedia] ❌ Mic track not assembled for \(manifest.tag) —"
                + " \(micURL.lastPathComponent) is missing, parts kept: \(parts)")
        }
    }

    func cancelEcho(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.echoCancelled else { return }
        defer {
            // Declining is a completed decision. Re-running cannot improve it.
            manifest.stages.echoCancelled = true
            manifest.save(in: dir)
        }
        guard SettingsManager.shared.enhanceRecordedCallAudio else {
            log("[CallMedia] AEC disabled — keeping raw call audio")
            return
        }
        guard let micURL = manifest.resolve(manifest.micFile, in: dir),
              let systemURL = manifest.resolve(manifest.systemFile, in: dir),
              FileManager.default.fileExists(atPath: micURL.path),
              EchoCanceller.shared.isAvailable else { return }
        if let cleaned = EchoCanceller.shared.process(micURL: micURL, systemURL: systemURL) {
            manifest.cleanedMicFile = cleaned.lastPathComponent
        }
    }

    func muxVideo(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.stages.muxed else { return }
        guard let screenURL = manifest.resolve(manifest.screenFile, in: dir),
              FileManager.default.fileExists(atPath: screenURL.path) else {
            manifest.stages.muxed = true
            return
        }
        let micURL = manifest.effectiveMicURL(in: dir)
        let systemURL = manifest.resolve(manifest.systemFile, in: dir)
        let muxed = AudioMuxer.shared.muxNow(
            screenURL: screenURL,
            micURL: micURL,
            systemURL: systemURL,
            micStartSeconds: manifest.micStartSeconds,
            systemStartSeconds: manifest.systemStartSeconds,
            videoStartSeconds: manifest.videoStartSeconds
        )
        let hasAudio = [micURL, systemURL]
            .contains { $0.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        manifest.stages.muxed = muxed || !hasAudio
        manifest.save(in: dir)
    }

    /// A killed recording has no segment list, but its ordered part files may
    /// still be recoverable by the stitcher.
    private func adoptOrphanParts(_ manifest: inout CallSessionManifest, in dir: URL) {
        guard !manifest.recordingFinished, manifest.segments.isEmpty else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let parts = Self.orphanMicParts(names: names, tag: manifest.tag)
        guard !parts.isEmpty else { return }
        log("[CallMedia] \(manifest.tag) was killed mid-recording — salvaging \(parts.count) mic part(s)")
        manifest.segments = parts.map {
            CallSessionManifest.record(.recovered(url: dir.appendingPathComponent($0)))
        }
    }
}
