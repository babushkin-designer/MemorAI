import XCTest
@testable import MemorAI

/// Exercises the real pipeline — ffmpeg decode, model sidecar, quality gate,
/// ffmpeg encode — on a synthetic call built from scratch. Skips itself when
/// the sidecar venv or the model weights are not installed, so a checkout
/// without them still has a green suite.
final class EchoCancellerIntegrationTests: XCTestCase {

    private let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private func makeFixture(in dir: URL) throws -> (mic: URL, system: URL) {
        // Far side: a 300 Hz tone that plays for the first half of the call.
        // Near side (the user): an 800 Hz tone in the second half.
        // The mic hears the user plus a delayed, quieter copy of the far side —
        // exactly the speaker leak this is meant to remove.
        let system = dir.appendingPathComponent("call_2026-01-01_00-00-00_system.m4a")
        let mic = dir.appendingPathComponent("call_2026-01-01_00-00-00_mic.m4a")

        let systemArgs = ["-y", "-v", "error",
                          "-f", "lavfi", "-i", "sine=frequency=300:duration=20:sample_rate=48000",
                          "-af", "volume=enable='between(t,0,10)':volume=1,volume=enable='gt(t,10)':volume=0",
                          "-c:a", "aac", system.path]
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: systemArgs).exitCode, 0)

        let micArgs = ["-y", "-v", "error",
                       "-f", "lavfi", "-i", "sine=frequency=800:duration=20:sample_rate=48000",
                       "-f", "lavfi", "-i", "sine=frequency=300:duration=20:sample_rate=48000",
                       "-filter_complex",
                       "[0:a]volume=enable='gt(t,10)':volume=1,volume=enable='between(t,0,10)':volume=0[near];" +
                       "[1:a]volume=enable='between(t,0,10)':volume=0.5,volume=enable='gt(t,10)':volume=0,adelay=150:all=1[echo];" +
                       "[near][echo]amix=inputs=2:duration=first:dropout_transition=0[out]",
                       "-map", "[out]", "-c:a", "aac", mic.path]
        XCTAssertEqual(ProcessRunner.run(ffmpeg, args: micArgs).exitCode, 0)
        return (mic, system)
    }

    func testPipelineProducesACleanedTrackOrDeclinesCleanly() throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("ffmpeg not installed")
        }
        guard EchoCanceller.shared.isAvailable else {
            throw XCTSkip("AEC sidecar or model weights not installed")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_aec_it_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try makeFixture(in: dir)
        let result = EchoCanceller.shared.process(micURL: fixture.mic, systemURL: fixture.system)

        // The raw mic must survive untouched either way — that is the whole
        // safety story of this feature.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mic.path))

        guard let cleaned = result else {
            // Declining is a valid outcome (pure tones are not speech, and the
            // model is trained on voices); it must simply not leave debris.
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertFalse(leftovers.contains { $0.contains(".aec.") },
                           "declined but left a cleaned file behind: \(leftovers)")
            return
        }

        XCTAssertEqual(cleaned.lastPathComponent, "call_2026-01-01_00-00-00_mic.aec.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
        // Whatever the gate decided, the name must not confuse the call scanner.
        XCTAssertEqual(CallHistory.parse(filename: cleaned.lastPathComponent)?.role, "mic.aec")
        let sessions = CallHistory.recentSessions(outputPath: dir.path)
        XCTAssertEqual(sessions.first?.micURL?.lastPathComponent,
                       "call_2026-01-01_00-00-00_mic.m4a",
                       "the cleaned copy must not replace the mic track in Recent Calls")
    }
}
