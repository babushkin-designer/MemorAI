import Foundation
import AVFoundation

/// On-disk record of one recording session and how far its post-processing got.
/// Written when the recording starts, updated as each stage completes, removed
/// when there is nothing left to do.
///
/// Why it exists: post-processing (publish mic → cancel echo → mux → transcribe)
/// takes minutes on a long call, and the process can go away in the middle of
/// it. On 2026-08-10 the user quit during a call; ffmpeg had already built
/// `call_<tag>_screen.muxing.mp4` with sound, the atomic swap never happened,
/// and the finished video was left silent. The timings the muxer needs live
/// only in the recorders' memory, so after a restart nothing could align the
/// tracks again. With this file the next launch picks the session up exactly
/// where it stopped.
///
/// File names are stored relative to the directory the manifest sits in, so
/// moving the data directory does not invalidate a pending session.
struct CallSessionManifest: Codable {

    /// One mic segment as MicRecorder closed it — enough to hand MicStitcher
    /// the same job after a restart, including the host-clock gap between
    /// segments that it bridges with silence.
    struct SegmentRecord: Codable {
        let file: String
        let firstHostSeconds: Double?
        let frameCount: Int64
        let sampleRate: Double
    }

    struct Stages: Codable {
        /// The canonical call_<tag>_mic.m4a holds the whole track.
        var micPublished = false
        /// The echo canceller has had its turn (declining counts as done).
        var echoCancelled = false
        var muxed = false
        var transcribed = false

        var allDone: Bool { micPublished && echoCancelled && muxed && transcribed }
    }

    static let currentVersion = 1
    static let suffix = "_session.json"
    /// Launches a stuck session is retried over before it is written off. A
    /// permanently broken input must not make every launch redo the same work.
    static let maxAttempts = 3

    var version = Self.currentVersion
    let tag: String
    var micFile: String?
    var systemFile: String?
    var screenFile: String?
    /// Host-clock starts (mic: first tap buffer; system/video: first PTS).
    var micStartSeconds: Double?
    var systemStartSeconds: Double?
    var videoStartSeconds: Double?
    var segments: [SegmentRecord] = []
    /// Set when the echo canceller produced a track worth using; the muxer and
    /// the transcriber consume this one instead of the raw mic.
    var cleanedMicFile: String?
    var stages = Stages()
    var attempts = 0
    /// False until the recorders have been finalized. A manifest written at
    /// start but never completed belongs to a session that was killed
    /// mid-recording — its tracks are whatever the writers managed to flush.
    var recordingFinished = false

    init(tag: String) {
        self.tag = tag
    }

    /// A manifest for a call whose own one is long gone — the recordings are on
    /// disk and only the transcript is missing. Everything before transcription
    /// is declared done, because the files it would have produced are already
    /// there and redoing them would cost an hour to change nothing.
    ///
    /// Without the original there are no host-clock starts, so the two speakers
    /// interleave from each track's own zero — off by however far apart the
    /// recorders started, which is tenths of a second.
    static func forRetranscribing(tag: String, mic: URL?, system: URL?, screen: URL?)
        -> CallSessionManifest {
        var manifest = CallSessionManifest(tag: tag)
        manifest.micFile = mic?.lastPathComponent
        manifest.systemFile = system?.lastPathComponent
        manifest.screenFile = screen?.lastPathComponent
        manifest.recordingFinished = true
        manifest.stages = Stages(micPublished: true, echoCancelled: true,
                                 muxed: true, transcribed: false)
        return manifest
    }

    // MARK: - Location

    static func url(forTag tag: String, in dir: URL) -> URL {
        dir.appendingPathComponent("call_\(tag)\(suffix)")
    }

    func url(in dir: URL) -> URL { Self.url(forTag: tag, in: dir) }

    /// Manifests of sessions whose post-processing has not finished, oldest
    /// first so a backlog is worked through in the order it happened.
    static func pending(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("call_") && $0.hasSuffix(suffix) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Persistence

    @discardableResult
    func save(in dir: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        do {
            // Atomically: a half-written manifest read after a crash would be
            // worse than no manifest at all.
            try data.write(to: url(in: dir), options: .atomic)
            return true
        } catch {
            log("[CallSession] ⚠️ Could not write the session manifest: \(error.localizedDescription)")
            return false
        }
    }

    static func load(_ url: URL) -> CallSessionManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CallSessionManifest.self, from: data),
              manifest.version <= currentVersion else { return nil }
        return manifest
    }

    func remove(in dir: URL) {
        try? FileManager.default.removeItem(at: url(in: dir))
    }

    // MARK: - Derived paths

    func resolve(_ name: String?, in dir: URL) -> URL? {
        name.map { dir.appendingPathComponent($0) }
    }

    /// The mic track downstream should consume: the cleaned copy when the echo
    /// canceller produced one worth using, the raw track otherwise.
    func effectiveMicURL(in dir: URL) -> URL? {
        resolve(cleanedMicFile, in: dir) ?? resolve(micFile, in: dir)
    }

    func micSegments(in dir: URL) -> [MicRecorder.Segment] {
        segments.map {
            MicRecorder.Segment(url: dir.appendingPathComponent($0.file),
                                firstBufferHostSeconds: $0.firstHostSeconds,
                                frameCount: $0.frameCount,
                                sampleRate: $0.sampleRate)
        }
    }

    static func record(_ segment: MicRecorder.Segment) -> SegmentRecord {
        SegmentRecord(file: segment.url.lastPathComponent,
                      firstHostSeconds: segment.firstBufferHostSeconds,
                      frameCount: Int64(segment.frameCount),
                      sampleRate: segment.sampleRate)
    }
}
