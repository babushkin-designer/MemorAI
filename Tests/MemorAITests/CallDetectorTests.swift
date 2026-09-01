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

    // MARK: - Splitting back-to-back calls

    /// The far side talking through the call app is what a mute sounds like:
    /// keep recording however long it lasts.
    func testMuteWithTheFarSideTalkingIsNeverSplit() {
        XCTAssertTrue(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: false,
            callAppQuietFor: nil, splitAfter: 180))
    }

    /// A short silence from the far side is a pause in the meeting, not its end.
    func testABriefQuietSpellIsNotASplit() {
        XCTAssertTrue(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: false,
            callAppQuietFor: 179, splitAfter: 180))
    }

    /// Music after the meeting: the Mac is not silent, so the old rule kept
    /// recording — for four hours, on 2026-09-01. The call app has said nothing
    /// for three minutes, so the meeting is over.
    func testMusicAfterTheMeetingEndsTheRecording() {
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: false,
            callAppQuietFor: 180, splitAfter: 180))
    }

    /// The split is scoped to a live recording — nothing to divide otherwise.
    func testQuietCallAppOutsideRecordingChangesNothing() {
        XCTAssertFalse(CallDetector.shouldStayInCall(
            recordingMode: false, systemAudioAvailable: true, systemAudioSilent: false,
            callAppQuietFor: 600, splitAfter: 180))
    }

    /// Callers that do not measure the call app's output get the old behaviour.
    func testWithoutTheNewSignalTheOldRuleStands() {
        XCTAssertTrue(CallDetector.shouldStayInCall(
            recordingMode: true, systemAudioAvailable: true, systemAudioSilent: false))
    }
}
