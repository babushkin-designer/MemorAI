import Foundation

/// Completed dictation audio deferred by a call survives application restart.
/// Metadata is published only after its audio copy exists; a failed copy keeps
/// the original source. Tests supply a temporary directory.
final class DictationPendingStore {
    struct Job: Codable {
        let file: String
        let language: String
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func recordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".m4a")
    }

    func persist(_ source: URL, language: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alreadyStored = source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        let destination = try (alreadyStored ? source : recordingURL())
        guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileReadNoSuchFile) }
        if !alreadyStored { try FileManager.default.copyItem(at: source, to: destination) }
        do {
            let data = try JSONEncoder().encode(Job(file: destination.lastPathComponent, language: language))
            try data.write(to: destination.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        } catch {
            if !alreadyStored { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        if !alreadyStored { try? FileManager.default.removeItem(at: source) }
        return destination
    }

    func pending() -> [(URL, String)] {
        let metadata = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []
        return metadata.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            guard let data = try? Data(contentsOf: $0), let job = try? JSONDecoder().decode(Job.self, from: data),
                  job.file == URL(fileURLWithPath: job.file).lastPathComponent, job.file.hasSuffix(".m4a") else { return nil }
            let audio = directory.appendingPathComponent(job.file)
            return FileManager.default.fileExists(atPath: audio.path) ? (audio, job.language) : nil
        }
    }

    func remove(_ audio: URL) {
        try? FileManager.default.removeItem(at: audio)
        if audio.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: audio.deletingPathExtension().appendingPathExtension("json"))
        }
    }
}
