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

    func testFaceTimeDaemonIsCallDespiteSystemPath() {
        XCTAssertTrue(CallDetector.isKnownCallDaemon("/usr/libexec/avconferenced"))
        XCTAssertTrue(CallDetector.isKnownCallDaemon("/System/Applications/FaceTime.app/Contents/MacOS/FaceTime"))
        XCTAssertFalse(CallDetector.isKnownCallDaemon("/System/Library/PrivateFrameworks/Siri.framework/corespeechd"))
        XCTAssertFalse(CallDetector.isKnownCallDaemon("/usr/libexec/assistantd"))
    }

    func testOutsideRecordingModeUnchanged() {
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: false, systemAudioAvailable: true, systemAudioSilent: false))
    }
}
