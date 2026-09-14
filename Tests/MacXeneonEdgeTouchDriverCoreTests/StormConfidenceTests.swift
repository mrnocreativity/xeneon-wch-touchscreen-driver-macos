import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class StormConfidenceTests: XCTestCase {
    func testFourPlausibleSamplesNoLongerAuthorizeContact() {
        let v = storm()
        for i in 0..<4 { XCTAssertTrue(v.process(e(.move, 8000, 4000, 20 + i * 8)).events.isEmpty) }
        XCTAssertTrue(v.process(e(.up, 8000, 4000, 60)).events.isEmpty)
        XCTAssertTrue(v.advanceConfidence(at: t(100)).events.isEmpty)
    }

    func testOutOfRangeStationaryNoiseCannotBecomeClampedEdgeTouch() {
        let v = TouchStreamValidator()
        for i in 0..<100 {
            XCTAssertTrue(v.process(e(.move, 65535, 65535, i * 8)).events.isEmpty)
        }
        XCTAssertTrue(v.isStormActive)
        XCTAssertFalse(v.allowsHold(at: t(800)))
    }

    func testTwoCompetingClustersNeverChooseArbitraryFinger() {
        let v = storm()
        for i in 0..<500 {
            let x = i.isMultiple(of: 2) ? 3000 : 13000
            XCTAssertTrue(v.process(e(.move, x, 4000, 20 + i * 8)).events.isEmpty)
        }
        XCTAssertFalse(v.stormSnapshot()!.hasAcquiredTrack)
    }

    func testPlausibleMinorityFragmentsInDenseNoiseCannotAcquire() {
        let v = storm()
        for i in 0..<1000 {
            let point = i.isMultiple(of: 3) ? (8000, 4000) :
                (i.isMultiple(of: 2) ? (100, 9000) : (15000, 100))
            XCTAssertTrue(v.process(e(.move, point.0, point.1, 20 + i * 8)).events.isEmpty)
        }
    }

    func testDominantStationaryFingerSurvivesOccasionalOutliers() {
        let v = storm()
        var events: [TouchEvent] = []
        for i in 0..<16 {
            let point = i == 2 || i == 8 ? (15000, 100) : (8000, 4000)
            events += v.process(e(.move, point.0, point.1, 20 + i * 8)).events
        }
        XCTAssertEqual(events.map(\.kind), [.down])
        XCTAssertTrue(v.process(e(.up, 8000, 4000, 148)).events.isEmpty)
        XCTAssertTrue(v.advanceConfidence(at: t(171)).events.isEmpty)
        XCTAssertEqual(v.advanceConfidence(at: t(172)).events.map(\.kind), [.up])
    }

    func testCurvedMotionRemainsTrackable() {
        let v = storm()
        var events: [TouchEvent] = []
        for i in 0..<30 {
            let angle = Double(i) * 0.06
            events += v.process(e(.move, 8000 + Int(1500 * cos(angle)),
                                  4000 + Int(900 * sin(angle)), 20 + i * 8)).events
        }
        XCTAssertEqual(events.first?.kind, .down)
        XCTAssertGreaterThan(events.count, 20)
        XCTAssertTrue(v.stormSnapshot()!.hasAcquiredTrack)
    }

    func testFreshSupportedStationaryTrackAllowsHoldButStaleTrackDoesNot() {
        let v = storm()
        acquire(v)
        XCTAssertTrue(v.allowsHold(at: t(85)))
        XCTAssertFalse(v.allowsHold(at: t(150)))
        XCTAssertTrue(v.advanceConfidence(at: t(150)).cancelActiveGesture)
        XCTAssertFalse(v.stormSnapshot()!.hasAcquiredTrack)
    }

    func testOutlierCannotBroadenTrackUntilItJumpsToNoise() {
        let v = storm()
        acquire(v)
        XCTAssertTrue(v.process(e(.move, 15000, 100, 92)).events.isEmpty)
        XCTAssertFalse(v.allowsHold(at: t(93)))
        let jump = v.process(e(.move, 11000, 4000, 140))
        XCTAssertTrue(jump.events.isEmpty)
        XCTAssertTrue(jump.cancelActiveGesture)
    }

    func testFalseReleaseRetractedByPressedInlierCannotProduceClick() {
        let v = storm()
        acquire(v)
        XCTAssertTrue(v.process(e(.up, 8000, 4000, 92)).events.isEmpty)
        XCTAssertFalse(v.allowsHold(at: t(94)))
        XCTAssertTrue(v.process(e(.down, 8000, 4000, 100)).events.isEmpty)
        XCTAssertEqual(v.lastDecision, "false_release_retracted")
        XCTAssertTrue(v.advanceConfidence(at: t(120)).events.isEmpty)
        XCTAssertTrue(v.advanceConfidence(at: t(160)).cancelActiveGesture)
        XCTAssertEqual(v.stormSnapshot()?.recoveredContacts, 0)
    }

    func testDistantReleaseAndLostTrackCancelWithoutTap() {
        let v = storm()
        acquire(v)
        XCTAssertTrue(v.process(e(.up, 15000, 9000, 92)).events.isEmpty)
        let result = v.advanceConfidence(at: t(160))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.cancelActiveGesture)
    }

    func testDelayedTimerCannotReplayAnOldClickAfterSchedulingStall() {
        let v = storm()
        acquire(v)
        _ = v.process(e(.up, 8000, 4000, 92))
        let result = v.advanceConfidence(at: t(500))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.cancelActiveGesture)
        XCTAssertEqual(v.lastDecision, "stale_release")
    }

    func testFrozenEntryCaptureReplaysTheSameDetection() throws {
        let original = storm()
        let samples = try XCTUnwrap(original.takeDiagnosticCapture(at: t(20)))
        let replay = TouchStreamValidator()
        for sample in samples {
            guard let x = sample.x, let y = sample.y else { continue }
            let kind: TouchEvent.Kind = sample.kind == "down" ? .down : sample.kind == "up" ? .up : .move
            _ = replay.process(TouchEvent(kind: kind, contactID: 0, rawX: x, rawY: y,
                timestamp: DispatchTime(uptimeNanoseconds: sample.uptimeNanoseconds)))
        }
        XCTAssertTrue(replay.isStormActive)
        XCTAssertEqual(replay.lastDecision, original.lastDecision)
    }

    func testSilenceLeavesProbationAndThreeCleanContactsRestoreNormal() {
        let v = storm()
        XCTAssertNotNil(v.recoverIfQuiet(at: t(1100)))
        XCTAssertTrue(v.isRecoveryProbation)
        XCTAssertFalse(v.needsConfidenceTimer)
        for index in 0..<3 {
            let start = 1200 + index * 200
            acquire(v, start: start)
            XCTAssertTrue(v.process(e(.up, 8000, 4000, start + 72)).events.isEmpty)
            XCTAssertEqual(v.advanceConfidence(at: t(start + 96)).events.map(\.kind), [.up])
            XCTAssertEqual(v.isRecoveryProbation, index != 2)
        }
        XCTAssertFalse(v.needsConfidenceTimer)
        XCTAssertTrue(v.process(e(.down, 8000, 4000, 2000)).events.isEmpty)
        XCTAssertEqual(v.process(e(.up, 8000, 4000, 2030)).events.map(\.kind), [.down, .up])
    }

    func testBriefQuietGapDoesNotRestoreSparseTapAcceptance() {
        let v = storm()
        _ = v.recoverIfQuiet(at: t(1100))
        for i in 0..<4 { XCTAssertTrue(v.process(e(.move, 8000, 4000, 1200 + i * 8)).events.isEmpty) }
        XCTAssertTrue(v.process(e(.up, 8000, 4000, 1240)).events.isEmpty)
        XCTAssertTrue(v.advanceConfidence(at: t(1300)).events.isEmpty)
        XCTAssertTrue(v.isRecoveryProbation)
    }

    func testOutOfOrderReportsRevokeTrackAndCannotCompleteTap() {
        let v = storm()
        acquire(v)
        XCTAssertTrue(v.process(e(.up, 8000, 4000, 30)).cancelActiveGesture)
        XCTAssertTrue(v.advanceConfidence(at: t(150)).events.isEmpty)
    }

    func testCaptureIsBoundedOrderedRoundTrippableAndRateLimited() throws {
        let v = storm()
        for i in 0..<2000 { v.recordRawReport(at: t(20 + i * 8)) }
        let ring = v.diagnosticSamples()
        XCTAssertEqual(ring.count, 256)
        XCTAssertEqual(ring.last?.uptimeNanoseconds, t(20 + 1999 * 8).uptimeNanoseconds)
        XCTAssertEqual(ring.map(\.uptimeNanoseconds), ring.map(\.uptimeNanoseconds).sorted())
        let capture = try XCTUnwrap(v.takeDiagnosticCapture(at: t(17000)))
        XCTAssertEqual(capture.count, 256)
        XCTAssertEqual(capture.first?.kind, "down", "Frozen entry capture retains pre-trigger evidence")
        let decoded = try JSONDecoder().decode([TouchStreamValidator.DiagnosticSample].self,
                                               from: JSONEncoder().encode(capture))
        XCTAssertEqual(decoded, capture)
        XCTAssertNil(v.takeDiagnosticCapture(at: t(17001)))
        XCTAssertNotNil(v.takeDiagnosticCapture(at: t(47000)))
    }

    func testNoiseOnOneValidatorDoesNotAffectHealthyPeer() {
        let noisy = storm(), healthy = TouchStreamValidator()
        acquire(noisy)
        XCTAssertTrue(healthy.process(e(.down, 8000, 4000, 20)).events.isEmpty)
        XCTAssertEqual(healthy.process(e(.up, 8000, 4000, 40)).events.map(\.kind), [.down, .up])
        XCTAssertFalse(healthy.isStormActive)
    }

    private func acquire(_ v: TouchStreamValidator, start: Int = 20) {
        var events: [TouchEvent] = []
        for i in 0..<9 { events += v.process(e(.move, 8000, 4000, start + i * 8)).events }
        XCTAssertEqual(events.map(\.kind), [.down])
    }

    private func storm() -> TouchStreamValidator {
        let v = TouchStreamValidator()
        _ = v.process(e(.down, 10410, 6120, 0))
        _ = v.process(e(.move, 11264, 4533, 8))
        XCTAssertTrue(v.isStormActive)
        return v
    }

    private func e(_ kind: TouchEvent.Kind, _ x: Int, _ y: Int, _ ms: Int) -> TouchEvent {
        TouchEvent(kind: kind, contactID: 0, rawX: x, rawY: y, timestamp: t(ms))
    }

    private func t(_ ms: Int) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: 1_000_000_000 + UInt64(ms) * 1_000_000)
    }
}
