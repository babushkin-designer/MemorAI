import XCTest
@testable import MemorAI

final class CallWorkGateTests: XCTestCase {
    func testDisableEnableIsReversibleAndDoesNotOpenAnActiveCall() {
        let gate = CallWorkGate()
        gate.setEnabled(false)
        XCTAssertTrue(gate.isBlocked)
        XCTAssertFalse(gate.isActive)
        XCTAssertNil(gate.launch { XCTFail("disabled work must not launch"); return Process() })
        gate.setEnabled(true)
        XCTAssertFalse(gate.isBlocked)
        gate.setActive(true)
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertTrue(gate.isBlocked)
        gate.setActive(false)
        XCTAssertFalse(gate.isBlocked)
        XCTAssertNotNil(gate.launch { Process() })
        gate.setEnabled(false)
        XCTAssertNil(gate.server)
    }
    func testClosedGateRejectsQueuedWarmupWithoutInvokingLauncher() {
        let gate = CallWorkGate()
        gate.setActive(true)
        var launched = false
        XCTAssertNil(gate.launch { launched = true; return Process() })
        XCTAssertFalse(launched)
        gate.setActive(false)
        XCTAssertNotNil(gate.launch { launched = true; return Process() })
        XCTAssertTrue(launched)
    }

    func testCallStartAndLaunchSerializeAndClearServer() {
        let gate = CallWorkGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ended = expectation(description: "launch returned")
        DispatchQueue.global().async {
            _ = gate.launch { entered.signal(); release.wait(); return Process() }
            ended.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let closed = expectation(description: "call closed gate")
        DispatchQueue.global().async { gate.setActive(true); closed.fulfill() }
        release.signal()
        wait(for: [ended, closed], timeout: 3)
        XCTAssertTrue(gate.isActive)
        XCTAssertNil(gate.server)
        XCTAssertNil(gate.launch { XCTFail("must not launch during call"); return Process() })
    }
}
