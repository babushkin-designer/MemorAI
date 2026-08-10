import XCTest
@testable import MemorAI

final class UnfairLockTests: XCTestCase {

    func testConcurrentMutationsAreSerialized() {
        // The mic tap mutates counters from the audio thread while the main
        // queue reads them; without the lock these increments lose updates.
        let lock = UnfairLock()
        var counter = 0
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            for _ in 0..<200 {
                lock.withLock { counter += 1 }
            }
        }
        XCTAssertEqual(counter, 500 * 200)
    }

    func testValuesAndErrorsPassThrough() {
        let lock = UnfairLock()
        XCTAssertEqual(lock.withLock { 42 }, 42)

        struct Boom: Error {}
        XCTAssertThrowsError(try lock.withLock { throw Boom() })
        // Still usable afterwards — the unlock happens on the throwing path too.
        XCTAssertEqual(lock.withLock { "ok" }, "ok")
    }

    func testStoppingARecorderThatNeverStartedIsANoOp() {
        let recorder = MicRecorder(outputURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_never_started_\(UUID().uuidString).m4a"))
        recorder.stop()
        recorder.stop()
        XCTAssertTrue(recorder.segments.isEmpty)
        XCTAssertNil(recorder.firstBufferHostSeconds)
    }

    func testPauseSwitchIsIdempotent() {
        let recorder = MicRecorder(outputURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai_pause_\(UUID().uuidString).m4a"))
        XCTAssertFalse(recorder.isPaused)
        recorder.isPaused = true
        recorder.isPaused = true
        XCTAssertTrue(recorder.isPaused)
        recorder.isPaused = false
        XCTAssertFalse(recorder.isPaused)
    }
}
