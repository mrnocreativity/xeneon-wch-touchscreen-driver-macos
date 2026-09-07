import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testObservationGapRevokesBothAmbiguousMappingsAndRequiresCalibration() throws {
        let displays = [display(id: 41, runtimeIdentifier: "LEFT", x: 0), display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)]
        let devices = [TouchDeviceIdentity(locationID: 1), TouchDeviceIdentity(locationID: 2)]
        let store = pairingStore()
        for (device, display) in zip(devices, displays) {
            try store.assign(device: device, to: display, connectedDevices: Set(devices), displays: displays)
        }
        let input = ApplicationRecordingInputSink()
        let app = recoveryApplication(store: store, input: input, displays: { displays })
        devices.forEach { app.handleDeviceMatched($0) }
        app.refreshDisplayMappings(reason: "test initial authority")
        app.loseObservation(reason: "test sleep or heartbeat gap")
        XCTAssertTrue(store.pairings.isEmpty)
        app.handleTouchEvent(deviceEvent(devices[0], .down, rawX: 0, rawY: 0))
        app.handleTouchEvent(deviceEvent(devices[0], .up, rawX: 0, rawY: 0))
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertTrue(app.handleControlCommand("status").contains("suspended"))
        app.resumeObservation()
        XCTAssertTrue(app.handleControlCommand("status").contains("calibrating"))
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testRemovedControllerLateReportCannotResurrectItOrOtherAmbiguousPairing() throws {
        let displays = [display(id: 41, runtimeIdentifier: "LEFT", x: 0), display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)]
        let devices = [TouchDeviceIdentity(locationID: 1), TouchDeviceIdentity(locationID: 2)]
        let store = pairingStore()
        for (device, display) in zip(devices, displays) {
            try store.assign(device: device, to: display, connectedDevices: Set(devices), displays: displays)
        }
        let input = ApplicationRecordingInputSink()
        let app = recoveryApplication(store: store, input: input, displays: { displays })
        devices.forEach { app.handleDeviceMatched($0) }
        app.refreshDisplayMappings(reason: "test initial authority")
        app.handleDeviceRemoval(devices[0])
        app.handleTouchEvent(deviceEvent(devices[0], .down, rawX: 0, rawY: 0))
        app.handleHIDReport(device: devices[0], timestamp: .now(), event: nil)
        app.refreshDisplayMappings(reason: "test removed endpoint")
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(app.handleControlCommand("status").utf8)) as? [String: Any])
        XCTAssertEqual((status["controllers"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testCanonicalCancelPreservesActiveInputButRePairRevokesIt() throws {
        let target = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let device = TouchDeviceIdentity(locationID: 1)
        let store = pairingStore()
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let input = ApplicationRecordingInputSink()
        let app = recoveryApplication(store: store, input: input, displays: { [target] })
        app.handleDeviceMatched(device)
        app.refreshDisplayMappings(reason: "test active pairing")
        XCTAssertTrue(app.handleControlCommand("cancel-pairing").contains("\"calibrationPaused\":true"))
        app.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        app.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))
        XCTAssertEqual(input.calls.count, 2)
        XCTAssertTrue(app.handleControlCommand("re-pair").contains("suspended"))
        XCTAssertTrue(store.pairings.isEmpty)
        app.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        app.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))
        XCTAssertEqual(input.calls.count, 2)
    }

    func testCancelStopsCalibrationAndQueuedReconciliationDoesNotReopenOverlay() {
        let target = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let device = TouchDeviceIdentity(locationID: 1)
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let app = recoveryApplication(store: store, overlay: overlay, displays: { [target] })
        app.handleDeviceMatched(device)
        app.refreshDisplayMappings(reason: "test prompt")
        _ = app.handleControlCommand("cancel-pairing")
        let count = overlay.calls.count
        performCalibration(app, device: device)
        waitForAsyncWork(milliseconds: 350)
        XCTAssertEqual(overlay.calls.count, count)
        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(app.handleControlCommand("status").contains("suspended"))
    }

    func testCalibrationRejectsStalePlacementAndChangeOnOtherDisplay() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        var displays = [left, right]
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let app = recoveryApplication(store: store, overlay: overlay, displays: { displays })
        let device = TouchDeviceIdentity(locationID: 1)
        app.handleDeviceMatched(device)
        app.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        app.refreshDisplayMappings(reason: "test initial prompt")
        displays = [left, display(id: 42, runtimeIdentifier: "RIGHT", x: 3_000)]
        performCalibration(app, device: device)
        XCTAssertTrue(store.pairings.isEmpty)
        app.refreshDisplayMappings(reason: "test new topology")
        overlay.ready = false
        performCalibration(app, device: device)
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testPersistenceFailureNeverActivatesCalibratedController() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PairingStore(url: url)
        let target = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let device = TouchDeviceIdentity(locationID: 1)
        let input = ApplicationRecordingInputSink()
        let app = recoveryApplication(store: store, input: input, displays: { [target] })
        app.handleDeviceMatched(device)
        app.refreshDisplayMappings(reason: "test prompt")
        performCalibration(app, device: device)
        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(app.handleControlCommand("status").contains("could not be persisted"))
        XCTAssertTrue(input.calls.isEmpty)
    }

    private func recoveryApplication(
        store: PairingStore,
        input: ApplicationRecordingInputSink = ApplicationRecordingInputSink(),
        overlay: ApplicationRecordingPairingOverlay = ApplicationRecordingPairingOverlay(),
        displays: @escaping () -> [DisplaySnapshot]
    ) -> MacXeneonEdgeTouchDriverApplication {
        MacXeneonEdgeTouchDriverApplication(configuration: immediateConfiguration(),
            displayResolver: DisplayResolver(activeDisplayProvider: displays), inputSink: input,
            cursorController: ApplicationRecordingCursorController(), pairingStore: store, pairingOverlay: overlay)
    }

    func testEachControllerGetsIndependentFocusRestorer() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        var focusRestorerCount = 0
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            focusRestorerProvider: {
                focusRestorerCount += 1
                return NoOpFocusRestorer()
            },
            pairingStore: pairingStore(),
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))

        XCTAssertEqual(focusRestorerCount, 2)
    }

    func testTwoPersistedControllersRouteToDifferentDisplays() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let first = TouchDeviceIdentity(locationID: 1)
        let second = TouchDeviceIdentity(locationID: 2)
        let devices: Set = [first, second]
        try store.assign(device: first, to: left, connectedDevices: devices, displays: [left, right])
        try store.assign(device: second, to: right, connectedDevices: devices, displays: [left, right])
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor,
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(first)
        application.handleDeviceMatched(second)
        application.handleTouchEvent(deviceEvent(first, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(first, .up, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(second, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(second, .up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 0, y: 200)),
            .mouseUp(CGPoint(x: 0, y: 200)),
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])
    }

    func testStormOnOneControllerProducesNoInputAndDoesNotDisableOtherController() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let storming = TouchDeviceIdentity(locationID: 11)
        let healthy = TouchDeviceIdentity(locationID: 12)
        let devices: Set = [storming, healthy]
        try store.assign(device: storming, to: left, connectedDevices: devices, displays: [left, right])
        try store.assign(device: healthy, to: right, connectedDevices: devices, displays: [left, right])
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(storming)
        application.handleDeviceMatched(healthy)
        application.handleTouchEvent(deviceEvent(
            storming,
            .down,
            rawX: 10_410,
            rawY: 6_120,
            timestampNanoseconds: 1_000_000_000
        ))
        application.handleTouchEvent(deviceEvent(
            storming,
            .move,
            rawX: 11_264,
            rawY: 4_533,
            timestampNanoseconds: 1_008_000_000
        ))

        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertTrue(application.hasStormRecoveryTimer(for: storming))

        application.handleTouchEvent(deviceEvent(
            healthy,
            .down,
            rawX: 0,
            rawY: 0,
            timestampNanoseconds: 2_000_000_000
        ))
        application.handleTouchEvent(deviceEvent(
            healthy,
            .up,
            rawX: 0,
            rawY: 0,
            timestampNanoseconds: 2_100_000_000
        ))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])

        application.handleStormRecoveryTick(
            for: storming,
            at: DispatchTime(uptimeNanoseconds: 2_100_000_000)
        )
        XCTAssertFalse(application.hasStormRecoveryTimer(for: storming))
    }

    func testStormingControllerRoutesAConfidentTapAndDropsInterleavedOutliers() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 0)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 11)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )
        application.handleDeviceMatched(device)

        let reports: [(TouchEvent.Kind, Int, Int, UInt64)] = [
            (.down, 10_410, 6_120, 1_000_000_000),
            (.move, 11_264, 4_533, 1_008_000_000),
            (.down, 8_000, 4_000, 1_020_000_000),
            (.move, 200, 9_000, 1_028_000_000),
            (.move, 8_010, 4_005, 1_036_000_000),
            (.move, 15_000, 300, 1_044_000_000),
            (.move, 8_020, 4_010, 1_052_000_000),
            (.move, 8_030, 4_015, 1_068_000_000),
            (.up, 8_032, 4_015, 1_084_000_000)
        ]
        for report in reports {
            application.handleTouchEvent(deviceEvent(
                device,
                report.0,
                rawX: report.1,
                rawY: report.2,
                timestampNanoseconds: report.3
            ))
        }

        XCTAssertEqual(input.calls.count, 2)
        guard case .mouseDown(let downPoint) = input.calls[0],
              case .mouseUp(let upPoint) = input.calls[1] else {
            return XCTFail("Expected one recovered click")
        }
        XCTAssertEqual(downPoint.x, upPoint.x, accuracy: 0.001)
        let expectedX = target.bounds.minX + target.bounds.width * 8_000 / 16_383
        XCTAssertEqual(downPoint.x, expectedX, accuracy: 0.001)
        application.handleDeviceRemoval(device)
    }

    func testTwoTargetCalibrationPairsWithoutSyntheticInput() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let device = TouchDeviceIdentity(locationID: 1)
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.refreshDisplayMappings(reason: "test calibration ready")
        performCalibration(application, device: device)

        XCTAssertEqual(
            store.resolveDisplay(for: device, connectedDevices: [device], displays: [target]),
            target
        )
        XCTAssertTrue(overlay.calls.contains(.confirmation("TARGET")))
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testAlreadyPairedControllerCannotStealSecondPairingTarget() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let paired = TouchDeviceIdentity(locationID: 1)
        let unpaired = TouchDeviceIdentity(locationID: 2)
        let devices: Set = [paired, unpaired]
        try store.assign(device: paired, to: left, connectedDevices: devices, displays: [left, right])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(paired)
        application.handleDeviceMatched(unpaired)
        application.handleTouchEvent(deviceEvent(paired, .down, rawX: 0, rawY: 0))

        XCTAssertEqual(
            store.resolveDisplay(for: paired, connectedDevices: devices, displays: [left, right]),
            left
        )
        XCTAssertNil(store.resolveDisplay(
            for: unpaired,
            connectedDevices: devices,
            displays: [left, right]
        ))
    }

    func testDisplayBoundsChangeUpdatesDestinationWithoutRecalibration() throws {
        var currentDisplay = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [currentDisplay] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(
            device: device,
            to: currentDisplay,
            connectedDevices: [device],
            displays: [currentDisplay]
        )
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )
        application.handleDeviceMatched(device)
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))

        currentDisplay = display(id: 41, runtimeIdentifier: "TARGET", x: 2_000)
        application.refreshDisplayMappings(reason: "test arrangement change")
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 100, y: 200)),
            .mouseUp(CGPoint(x: 100, y: 200)),
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])
    }

    func testControllerRemovalInvalidatesBootSessionPairing() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(device)
        application.handleDeviceRemoval(device)

        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testDisplayMembershipChangeInvalidatesBootSessionPairingAndHidesOverlay() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.handleDisplayReconfiguration(displayID: target.displayID, flags: .removeFlag)
        waitForAsyncWork(milliseconds: 100)

        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(overlay.calls.contains(.hide))
    }

    func testBoundsOnlyDisplayChangePreservesBootSessionPairing() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(device)
        application.handleDisplayReconfiguration(displayID: target.displayID, flags: .movedFlag)
        waitForAsyncWork(milliseconds: 100)

        XCTAssertEqual(store.pairings.count, 1)
        XCTAssertEqual(
            store.resolveDisplay(for: device, connectedDevices: [device], displays: [target]),
            target
        )
    }

    func testUnavailableOverlayDoesNotAuthorizeTouchRouting() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay(canShow: false)
        let device = TouchDeviceIdentity(locationID: 1)
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.refreshDisplayMappings(reason: "test screen readiness lag")
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))

        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testStagedDeviceEnumerationIsDebouncedIntoOneReconciliation() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        waitForAsyncWork(milliseconds: 400)

        XCTAssertEqual(overlay.calls.filter {
            if case .show = $0 { return true }
            return false
        }, [.show("LEFT", 1, 2)])
    }

    func testIncompleteReconnectTopologyDoesNotPresentPairingOverlay() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let resolver = DisplayResolver(activeDisplayProvider: { [left] })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay,
            pairingTopologyRetryDelay: .seconds(60)
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        application.refreshDisplayMappings(reason: "test incomplete reconnect")

        XCTAssertFalse(overlay.calls.contains { call in
            if case .show = call { return true }
            return false
        })
    }

    func testIncompleteReconnectTopologyRetriesWhenMissingDisplayAppears() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        var displays = [left]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay,
            pairingTopologyRetryDelay: .milliseconds(50)
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        application.refreshDisplayMappings(reason: "test incomplete reconnect")
        displays = [left, right]
        // Queued HID-match reconciliation debounces for 250ms before the 50ms topology retry.
        waitForAsyncWork(milliseconds: 400)

        XCTAssertTrue(overlay.calls.contains(.show("LEFT", 1, 2)))
    }

    func testProductionTopologyGateRequiresTwoIdenticalObservations() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay,
            requiredStablePairingTopologyObservations: 2,
            pairingTopologyRetryDelay: .seconds(60)
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        application.refreshDisplayMappings(reason: "test first stable observation")
        XCTAssertFalse(overlay.calls.contains(.show("LEFT", 1, 2)))

        application.refreshDisplayMappings(reason: "test second stable observation")
        XCTAssertTrue(overlay.calls.contains(.show("LEFT", 1, 2)))
    }

    func testChangedBoundsResetPairingTopologyStability() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        var right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay,
            requiredStablePairingTopologyObservations: 2,
            pairingTopologyRetryDelay: .seconds(60)
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        application.refreshDisplayMappings(reason: "test initial bounds")
        right = display(id: 42, runtimeIdentifier: "RIGHT", x: 3_000)
        application.refreshDisplayMappings(reason: "test changed bounds")
        XCTAssertFalse(overlay.calls.contains(.show("LEFT", 1, 2)))

        application.refreshDisplayMappings(reason: "test stable changed bounds")
        XCTAssertTrue(overlay.calls.contains(.show("LEFT", 1, 2)))
    }

    func testPairingOverlayRetriesUntilAppKitScreenBecomesReady() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay(failuresBeforeSuccess: 2)
        let device = TouchDeviceIdentity(locationID: 1)
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.refreshDisplayMappings(reason: "test initial screen readiness")
        waitForAsyncWork(milliseconds: 1_100)
        XCTAssertEqual(overlay.calls.filter {
            if case .show = $0 { return true }
            return false
        }.count, 3)
        performCalibration(application, device: device)
        XCTAssertEqual(store.pairings.count, 1)
    }

    private func performCalibration(_ application: MacXeneonEdgeTouchDriverApplication, device: TouchDeviceIdentity) {
        for x in [4_096, 12_287] {
            let start = DispatchTime.now().uptimeNanoseconds + 1_000_000
            application.handleTouchEvent(deviceEvent(device, .down, rawX: x, rawY: 4_800, timestampNanoseconds: start))
            application.handleTouchEvent(deviceEvent(device, .up, rawX: x, rawY: 4_800, timestampNanoseconds: start + 80_000_000))
        }
    }

    private func immediateConfiguration() -> DriverConfiguration {
        var configuration = DriverConfiguration.defaults
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        return configuration
    }

    private func display(id: CGDirectDisplayID, runtimeIdentifier: String, x: CGFloat) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            runtimeIdentifier: runtimeIdentifier,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 0,
            bounds: CGRect(
                x: x,
                y: 200,
                width: CGFloat(CapturedXeneonDisplay.expectedWidth),
                height: CGFloat(CapturedXeneonDisplay.expectedHeight)
            ),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private func pairingStore() -> PairingStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PairingStore(url: directory.appendingPathComponent("pairings.json"))
    }

    private func deviceEvent(
        _ device: TouchDeviceIdentity,
        _ kind: TouchEvent.Kind,
        rawX: Int,
        rawY: Int,
        timestampNanoseconds: UInt64? = nil
    ) -> DeviceTouchEvent {
        DeviceTouchEvent(
            device: device,
            touch: TouchEvent(
                kind: kind,
                contactID: 0,
                rawX: rawX,
                rawY: rawY,
                timestamp: timestampNanoseconds.map(DispatchTime.init(uptimeNanoseconds:)) ?? .now()
            )
        )
    }

    private func waitForAsyncWork(milliseconds: Int) {
        let expectation = expectation(description: "asynchronous driver work")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: Double(milliseconds) / 1_000 + 1)
    }
}

private final class ApplicationRecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
        case scroll(CGFloat, CGFloat, SyntheticScrollPhase)
    }

    private(set) var calls: [Call] = []
    func postMouseDown(at point: CGPoint, clickCount: Int) { calls.append(.mouseDown(point)) }
    func postMouseUp(at point: CGPoint, clickCount: Int) { calls.append(.mouseUp(point)) }
    func postMouseDragged(to point: CGPoint) { calls.append(.mouseDragged(point)) }
    func postScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase) {
        calls.append(.scroll(deltaX, deltaY, phase))
    }
}

private final class ApplicationRecordingCursorController: CursorController {
    enum Call: Equatable { case borrow(CGPoint), update(CGPoint), returnToOrigin, forceShow }
    private(set) var calls: [Call] = []
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) { calls.append(.update(point)) }
    func returnToOrigin() { calls.append(.returnToOrigin) }
    func forceShow() { calls.append(.forceShow) }
}

private final class ApplicationRecordingPairingOverlay: PairingOverlayPresenting {
    enum Call: Equatable {
        case show(String, Int, Int)
        case confirmation(String)
        case hide
    }
    private let lock = NSLock()
    private var storedCalls: [Call] = []
    private let canShow: Bool
    private var failuresBeforeSuccess: Int
    var ready = true
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }
    init(canShow: Bool = true, failuresBeforeSuccess: Int = 0) {
        self.canShow = canShow
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }
    func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append(.show(display.runtimeIdentifier, step, total))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            return false
        }
        return canShow
    }
    func showTarget(on display: DisplaySnapshot, step: Int, total: Int, targetIndex: Int) -> Bool {
        show(on: display, step: step, total: total)
    }
    func isReady(on display: DisplaySnapshot) -> Bool { ready }
    func showConfirmation(on display: DisplaySnapshot) {
        lock.lock()
        storedCalls.append(.confirmation(display.runtimeIdentifier))
        lock.unlock()
    }
    func hide() {
        lock.lock()
        storedCalls.append(.hide)
        lock.unlock()
    }
}
