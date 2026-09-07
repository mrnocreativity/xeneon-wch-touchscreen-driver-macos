import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PairingAuthorityTests: XCTestCase {
    func testHeartbeatExpiryBlocksRoutingWithoutWaitingForQueueCallback() {
        var now: UInt64 = 1_000_000_000
        let gate = ObservationGate(now: { now })
        gate.start()
        XCTAssertTrue(gate.allowsRouting)
        now += 4_000_000_000
        XCTAssertFalse(gate.isFresh)
        XCTAssertFalse(gate.allowsRouting)
        gate.externalChange()
        gate.acknowledge()
        XCTAssertTrue(gate.isFresh)
        XCTAssertFalse(gate.allowsRouting)
        XCTAssertTrue(gate.resume(ifRevision: gate.revision))
        XCTAssertTrue(gate.allowsRouting)
        gate.stop()
        XCTAssertFalse(gate.resume(ifRevision: gate.revision))
        XCTAssertFalse(gate.allowsRouting)
    }
    func testOneCompleteFreshContactConfirmsTarget() {
        var challenge = PairingChallenge(readyAt: 1_000_000_000, generation: 7)
        XCTAssertEqual(challenge.consume(event(.down, x: 8_192, at: 900_000_000)), .waiting)
        XCTAssertEqual(challenge.consume(event(.up, x: 8_192, at: 1_100_000_000)), .waiting)
        XCTAssertEqual(challenge.consume(event(.down, x: 8_192, at: 2_000_000_000)), .waiting)
        XCTAssertEqual(challenge.consume(event(.up, x: 8_192, at: 2_080_000_000)), .complete)
    }

    func testCompetingControllerCannotCompleteCalibration() {
        var challenge = PairingChallenge(readyAt: 0, generation: 1)
        _ = challenge.consume(event(.down, x: 8_192, at: 1_000_000_000))
        XCTAssertEqual(challenge.consume(event(.up, x: 8_192, at: 1_080_000_000, controller: 2)), .rejected)
    }

    func testWrongTargetAndFastNoiseAreRejected() {
        var challenge = PairingChallenge(readyAt: 0, generation: 1)
        XCTAssertEqual(challenge.consume(event(.down, x: 12_287, at: 1_000_000_000)), .rejected)
        challenge = PairingChallenge(readyAt: 0, generation: 1)
        _ = challenge.consume(event(.down, x: 8_192, at: 1_000_000_000))
        XCTAssertEqual(challenge.consume(event(.up, x: 8_192, at: 1_001_000_000)), .rejected)
    }

    func testDraggingOffTargetAndLongHoldAreRejected() {
        var challenge = PairingChallenge(readyAt: 0, generation: 1)
        _ = challenge.consume(event(.down, x: 8_192, at: 1_000_000_000))
        XCTAssertEqual(challenge.consume(event(.move, x: 4_096, at: 1_080_000_000)), .rejected)
        challenge = PairingChallenge(readyAt: 0, generation: 1)
        _ = challenge.consume(event(.down, x: 8_192, at: 1_000_000_000))
        XCTAssertEqual(challenge.consume(event(.up, x: 8_192, at: 4_000_000_000)), .rejected)
    }

    func testOldReconciliationCannotReopenGateAfterExternalChange() {
        let gate = ObservationGate()
        let revision = gate.revision
        gate.externalChange()
        XCTAssertFalse(gate.allowsRouting)
        XCTAssertFalse(gate.resume(ifRevision: revision))
        XCTAssertFalse(gate.allowsRouting)
        XCTAssertTrue(gate.resume(ifRevision: gate.revision))
        XCTAssertTrue(gate.allowsRouting)
    }

    private func event(_ kind: TouchEvent.Kind, x: Int, at timestamp: UInt64, controller: UInt32 = 1) -> DeviceTouchEvent {
        DeviceTouchEvent(device: TouchDeviceIdentity(locationID: controller), touch: TouchEvent(
            kind: kind, contactID: 0, rawX: x, rawY: 4_800,
            timestamp: DispatchTime(uptimeNanoseconds: timestamp)))
    }
}
