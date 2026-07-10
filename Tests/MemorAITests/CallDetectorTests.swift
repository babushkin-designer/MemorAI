import XCTest
@testable import MemorAI

final class CallDetectorTests: XCTestCase {

    func testMutedInCallAppKeepsRecordingWhileFarSideTalks() {
        // Mic released (mute) but system audio active → still in call
        XCTAssertTrue(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: false))
    }

    func testCallEndsWhenSystemAudioAlsoSilent() {
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: true))
    }

    func testMicOnlySessionEndsOnMicRelease() {
        // No system audio ever arrived (voice memo / headphones edge) —
        // mic release must end the call as before.
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: false, systemAudioSilent: false))
    }

    func testOutsideRecordingModeUnchanged() {
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: false, systemAudioAvailable: true, systemAudioSilent: false))
    }
}
