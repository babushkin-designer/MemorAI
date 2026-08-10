import XCTest
import ObjCTry

/// The shim is what stands between an AVFAudio device-transition raise and a
/// process abort, so it is worth proving it actually catches one.
final class ObjCTryTests: XCTestCase {

    func testRaisedExceptionBecomesAnError() {
        var error: NSError?
        let completed = MEMRunCatchingExceptions({
            NSException(name: .invalidArgumentException, reason: "boom", userInfo: nil).raise()
        }, &error)

        XCTAssertFalse(completed)
        XCTAssertEqual(error?.domain, MEMObjCExceptionDomain)
        XCTAssertTrue(error?.localizedDescription.contains("boom") ?? false,
                      error?.localizedDescription ?? "no description")
    }

    func testBlockThatDoesNotRaiseReportsSuccess() {
        var ran = false
        var error: NSError?
        let completed = MEMRunCatchingExceptions({ ran = true }, &error)

        XCTAssertTrue(completed)
        XCTAssertTrue(ran)
        XCTAssertNil(error)
    }

    func testExceptionWithoutAReasonStillProducesAnError() {
        var error: NSError?
        let completed = MEMRunCatchingExceptions({
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
        }, &error)

        XCTAssertFalse(completed)
        XCTAssertNotNil(error)
    }
}
