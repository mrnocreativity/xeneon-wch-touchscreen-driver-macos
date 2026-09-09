import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ObservationIsolationTests: XCTestCase {
    func testSlowFileWriterCannotBlockOrGrowDiagnosticQueue() {
        let queue = BoundedDiagnosticQueue(capacity: 2)
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        queue.submit { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        queue.submit {}
        for _ in 0..<100 { queue.submit { XCTFail("Full queue must drop file copies") } }
        XCTAssertEqual(queue.droppedCount, 100)
        release.signal()
        queue.flush()
        queue.submit {}
        queue.flush()
        XCTAssertEqual(queue.droppedCount, 100)
    }

    func testEndpointRunLoopAdvancesWhileCallingThreadIsBlockedAndStopsCleanly() throws {
        let worker = HIDRunLoopWorker()
        let pulse = DispatchSemaphore(value: 0)
        var timer: CFRunLoopTimer?
        try worker.start {
            XCTAssertFalse(Thread.isMainThread)
            timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0) { _ in pulse.signal() }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        }
        XCTAssertEqual(pulse.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(pulse.wait(timeout: .now() + 2), .success)
        worker.stop {
            XCTAssertFalse(Thread.isMainThread)
            if let timer { CFRunLoopTimerInvalidate(timer) }
        }
        worker.stop { XCTFail("Stop must be idempotent") }
    }

    func testEndpointRunLoopStartupFailurePropagatesWithoutHangingStop() {
        enum Failure: Error { case expected }
        let worker = HIDRunLoopWorker()
        XCTAssertThrowsError(try worker.start { throw Failure.expected })
        worker.stop { XCTFail("Failed startup has no running observer") }
    }
}
