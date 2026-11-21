import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class WindowFocusTransactionTests: XCTestCase {
    private let point = CGPoint(x: 40, y: 80)

    func testAlreadyFocusedWindowNeedsNoActivation() {
        let h = FocusHarness()
        h.focused = "browser-window"
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertTrue(h.activations.isEmpty)
        h.transaction.restore()
        XCTAssertTrue(h.activations.isEmpty)
    }

    func testInactiveWindowMustAcquireExactFocusBeforeCompletion() {
        let h = FocusHarness()
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        XCTAssertNil(result)
        XCTAssertEqual(h.activations, ["browser-window"])
        h.focused = "other-browser-window"
        h.advance(to: 0.02)
        XCTAssertEqual(result, false, "Activating the app is insufficient when its other window owns focus")
    }

    func testSuccessfulActivationRestoresOriginalExactWindowOnce() {
        let h = FocusHarness()
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        h.focused = "browser-window"
        h.advance(to: 0.02)
        XCTAssertEqual(result, true)
        XCTAssertTrue(h.transaction.ownsFocus())
        h.transaction.restore()
        h.transaction.restore()
        XCTAssertEqual(h.activations, ["browser-window", "mail-compose-window"])
    }

    func testActivationTimesOutWithoutReactivating() {
        let h = FocusHarness()
        h.transaction.capture()
        var results: [Bool] = []
        h.transaction.prepare(at: point) { results.append($0) }
        h.advance(to: 1)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(h.activations, ["browser-window"])
        h.transaction.restore()
        XCTAssertEqual(h.activations, ["browser-window"])
    }

    func testLateNativeActivationCannotReleaseInputAfterDeadline() {
        let h = FocusHarness()
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        h.focused = "browser-window"
        h.time = 1
        h.work.removeFirst().1()
        XCTAssertEqual(result, false)
    }

    func testUserSwitchDuringActivationCancelsAndDoesNotRestore() {
        let h = FocusHarness()
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        h.focused = "terminal-window"
        h.advance(to: 0.02)
        XCTAssertEqual(result, false)
        h.transaction.restore()
        XCTAssertEqual(h.activations, ["browser-window"])
    }

    func testUserSwitchAfterClickPreservesNewFocus() {
        let h = FocusHarness()
        h.transaction.capture()
        h.transaction.prepare(at: point) { _ in }
        h.focused = "browser-window"
        h.advance(to: 0.02)
        h.focused = "mail-other-window"
        XCTAssertFalse(h.transaction.ownsFocus())
        h.transaction.restore()
        XCTAssertEqual(h.activations, ["browser-window"])
    }

    func testCancelledActivationCannotCompleteLaterButCanRestoreBorrowedFocus() {
        let h = FocusHarness()
        h.transaction.capture()
        var results: [Bool] = []
        h.transaction.prepare(at: point) { results.append($0) }
        h.focused = "browser-window"
        h.transaction.cancelPreparation()
        h.advance(to: 1)
        XCTAssertTrue(results.isEmpty)
        h.transaction.restore()
        XCTAssertEqual(h.activations, ["browser-window", "mail-compose-window"])
    }

    func testWindowUnderTouchChangingDuringActivationRejectsInput() {
        let h = FocusHarness()
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        h.focused = "browser-window"
        h.resolved = "dialog-window"
        h.advance(to: 0.02)
        XCTAssertEqual(result, false)
    }

    func testMissingWindowFailsWithoutActivation() {
        let h = FocusHarness()
        h.resolved = nil
        h.transaction.capture()
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(h.activations.isEmpty)
    }

    func testContinuationDoesNotReclaimFocusAfterUserSwitch() {
        let h = FocusHarness()
        h.transaction.capture()
        h.transaction.prepare(at: point) { _ in }
        h.focused = "browser-window"
        h.advance(to: 0.02)
        h.focused = "terminal-window"
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(h.activations, ["browser-window"])
    }

    func testFocusChangedBetweenCaptureAndPreparationIsRespected() {
        let h = FocusHarness()
        h.transaction.capture()
        h.focused = "terminal-window"
        var result: Bool?
        h.transaction.prepare(at: point) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(h.activations.isEmpty)
    }

    func testAnotherControllerInheritsOriginalFocusWithoutAnIntermediateActivation() {
        let first = FocusHarness()
        first.transaction.capture()
        first.transaction.prepare(at: point) { _ in }
        first.focused = "browser-window"
        first.advance(to: 0.02)
        let second = FocusHarness()
        second.focused = "browser-window"
        second.transaction.capture(inheriting: first.transaction)
        var result: Bool?
        second.transaction.prepare(at: point) { result = $0 }
        XCTAssertEqual(result, true)
        first.transaction.restore()
        XCTAssertEqual(first.activations, ["browser-window"], "Old controller cannot restore during the new gesture")
        second.transaction.restore()
        XCTAssertEqual(second.activations, ["mail-compose-window"])
    }

    func testRestorationFailureIsReportedWithoutRepeatedActivation() {
        let h = FocusHarness()
        h.transaction.capture()
        h.transaction.prepare(at: point) { _ in }
        h.focused = "browser-window"
        h.advance(to: 0.02)
        var failures = 0
        h.transaction.restore { failures += 1 }
        h.advance(to: 1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(h.activations, ["browser-window", "mail-compose-window"])
    }
}

private final class FocusHarness {
    var focused: String? = "mail-compose-window"
    var resolved: String? = "browser-window"
    var activations: [String] = []
    var time: TimeInterval = 0
    var work: [(TimeInterval, () -> Void)] = []
    lazy var transaction = WindowFocusTransaction<String>(
        focusedWindow: { [unowned self] in self.focused },
        windowAtPoint: { [unowned self] _ in self.resolved },
        activate: { [unowned self] in self.activations.append($0) },
        schedule: { [unowned self] delay, action in self.work.append((self.time + delay, action)) },
        now: { [unowned self] in self.time }
    )

    func advance(to deadline: TimeInterval) {
        while let next = work.enumerated().filter({ $0.element.0 <= deadline }).min(by: { $0.element.0 < $1.element.0 }) {
            let item = work.remove(at: next.offset)
            time = item.0
            item.1()
        }
        time = deadline
    }
}
