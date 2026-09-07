import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Production wiring for independent, persisted touchscreen-to-display sessions.
public final class MacXeneonEdgeTouchDriverApplication {
    private let configuration: DriverConfiguration
    private let displayResolver: DisplayResolver
    private let pairingStore: PairingStore
    private let pairingOverlay: PairingOverlayPresenting
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorerProvider: () -> FocusRestorer
    private let requiredStablePairingTopologyObservations: Int
    private let pairingTopologyRetryDelay: DispatchTimeInterval

    private lazy var hidMonitor = HIDDeviceMonitor(
        eventQueue: gestureQueue,
        seizeDevice: true,
        touchReportHandler: { [weak self] device, timestamp, event in
            self?.handleHIDReport(device: device, timestamp: timestamp, event: event)
        },
        deviceRemovalHandler: { [weak self] device in self?.handleDeviceRemoval(device) },
        deviceMatchedHandler: { [weak self] device in self?.handleDeviceMatched(device) },
        topologyChangeHandler: { [weak self] in self?.observationGate.externalChange() }
    )

    private var connectedDevices: Set<TouchDeviceIdentity> = []
    private var suppressedUntilUp: Set<TouchDeviceIdentity> = []
    private var sessions: [TouchDeviceIdentity: DeviceTouchSession] = [:]
    private var compatibleDisplays: [DisplaySnapshot] = []
    private var pairingTarget: DisplaySnapshot?
    private var pairingAdvanceWork: DispatchWorkItem?
    private var reconciliationWork: DispatchWorkItem?
    private var screenParametersObserver: NSObjectProtocol?
    private var overlayPresentationAttempt = 0
    private var pairingTopologySignature: PairingTopologySignature?
    private var stablePairingTopologyObservationCount = 0
    private var pairingTopologyWaitDescription: String?
    private var activeGestureDevice: TouchDeviceIdentity?
    private var stuckGestureTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var didRegisterDisplayCallback = false
    private var isApplicationEventLoopRunning = false
    private var isRunning = false
    private var authority: [TouchDeviceIdentity: PairingAuthority] = [:]
    private var generation: UInt64 = 0
    private var challenge: PairingChallenge?
    private var challengeTimeout: DispatchWorkItem?
    private var configurationPending = false
    private var configurationStartedAt: UInt64 = 0
    private var observationLost = false
    private var sleeping = false
    private var calibrationPaused = false
    private var lastObservedDisplays: [DisplaySnapshot]?
    private var topologyPoll: DispatchSourceTimer?
    private var heartbeatPending = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private let control = DriverControl()
    private let observationGate = ObservationGate()

    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController(),
            focusRestorerProvider: { AXFocusRestorer() },
            pairingStore: PairingStore(),
            pairingOverlay: PairingOverlayController(),
            requiredStablePairingTopologyObservations: 2,
            pairingTopologyRetryDelay: .milliseconds(750)
        )
    }

    public init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorerProvider: @escaping () -> FocusRestorer = { NoOpFocusRestorer() },
        pairingStore: PairingStore = PairingStore(),
        pairingOverlay: PairingOverlayPresenting = PairingOverlayController(),
        requiredStablePairingTopologyObservations: Int = 1,
        pairingTopologyRetryDelay: DispatchTimeInterval = .milliseconds(750)
    ) {
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorerProvider = focusRestorerProvider
        self.pairingStore = pairingStore
        self.pairingOverlay = pairingOverlay
        self.requiredStablePairingTopologyObservations = max(
            requiredStablePairingTopologyObservations,
            1
        )
        self.pairingTopologyRetryDelay = pairingTopologyRetryDelay
    }

    deinit { stop() }

    public func run() -> Int32 {
        guard !isRunning else { return EXIT_SUCCESS }
        isRunning = true

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        DriverLoggers.log(.notice, category: .lifecycle, "Starting independent multi-display touch driver.")

        guard verifySyntheticEventPermission() else {
            stop()
            return EXIT_FAILURE
        }

        registerDisplayReconfigurationCallback()
        guard didRegisterDisplayCallback else {
            stop()
            return EXIT_FAILURE
        }
        registerScreenParametersObserver()
        installSignalHandlers()

        do {
            try control.start { [weak self] command, reply in
                guard let self else { reply("{\"error\":\"Driver stopped\"}"); return }
                self.gestureQueue.async { reply(self.handleControlCommand(command)) }
            }
            try hidMonitor.start()
        } catch {
            DriverLoggers.log(.fault, category: .lifecycle, "Could not start HID monitor: \(error.localizedDescription)")
            stop()
            return EXIT_FAILURE
        }

        scheduleDisplayReconciliation(reason: "startup", delay: .milliseconds(500))
        startObservation()

        isApplicationEventLoopRunning = true
        NSApp.run()
        isApplicationEventLoopRunning = false
        return EXIT_SUCCESS
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        observationGate.stop()
        hidMonitor.stop()
        control.stop()
        topologyPoll?.cancel()
        topologyPoll = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        unregisterDisplayReconfigurationCallback()
        unregisterScreenParametersObserver()
        signalSources.removeAll()
        // Never synchronously wait for the gesture queue from AppKit: an in-flight
        // overlay placement may itself be waiting for the main thread.
        gestureQueue.async { [self] in
            cancelStuckGestureTimer()
            challengeTimeout?.cancel()
            pairingAdvanceWork?.cancel()
            reconciliationWork?.cancel()
            sessions.values.forEach {
                $0.cancelStormRecoveryTimer()
                $0.gesture.forceCancel()
            }
            sessions.removeAll()
            activeGestureDevice = nil
            DispatchQueue.main.async { [self] in
                pairingOverlay.hide()
                DriverLoggers.log(.notice, category: .lifecycle, "Stopped multi-display touch driver.")
                stopApplicationEventLoop()
            }
        }
    }

    func handleDisplayReconfiguration(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        observationGate.externalChange()
        gestureQueue.async { [weak self] in
            guard let self else { return }
            self.suspendRouting(reason: "Display configuration changing")

            if flags.contains(.beginConfigurationFlag) {
                self.configurationPending = true
                self.configurationStartedAt = DispatchTime.now().uptimeNanoseconds
                return
            }
            self.configurationPending = false

            let changesMembership = flags.contains(.addFlag) ||
                flags.contains(.removeFlag) ||
                flags.contains(.enabledFlag) ||
                flags.contains(.disabledFlag)
            if changesMembership {
                do {
                    try self.pairingStore.invalidateAmbiguous()
                } catch {
                    DriverLoggers.log(
                        .error,
                        category: .display,
                        "Could not invalidate pairing after display membership changed: \(error.localizedDescription)"
                    )
                }
            }

            self.scheduleDisplayReconciliation(
                reason: "display reconfiguration for ID \(displayID), flags \(flags.rawValue)"
            )
        }
    }

    func handleDeviceMatched(_ device: TouchDeviceIdentity) {
        if !connectedDevices.contains(device), lastObservedDisplays != nil {
            suspendRouting(reason: "Controller membership changed")
            do { try pairingStore.invalidateAmbiguous() }
            catch { DriverLoggers.log(.error, category: .display, "Could not persist controller revocation: \(error)") }
        }
        if let old = connectedDevices.first(where: { $0.locationID == device.locationID && $0 != device }) {
            handleDeviceRemoval(old)
        }
        connectedDevices.insert(device)
        ensureSession(for: device)
        scheduleDisplayReconciliation(reason: "HID device match at \(device.hexadecimalLocationID)")
    }

    func handleDeviceRemoval(_ device: TouchDeviceIdentity) {
        suspendRouting(reason: "Controller disconnected")
        connectedDevices.remove(device)
        authority.removeValue(forKey: device)
        suppressedUntilUp.remove(device)
        sessions[device]?.cancelStormRecoveryTimer()
        if activeGestureDevice == device {
            sessions[device]?.gesture.forceCancel()
            activeGestureDevice = nil
            cancelStuckGestureTimer()
        }
        sessions.removeValue(forKey: device)
        do {
            try pairingStore.invalidateAmbiguous()
        } catch {
            DriverLoggers.log(
                .error,
                category: .display,
                "Could not invalidate pairing after controller removal: \(error.localizedDescription)"
            )
        }
        scheduleDisplayReconciliation(reason: "HID device removal at \(device.hexadecimalLocationID)")
    }

    func handleHIDReport(
        device: TouchDeviceIdentity,
        timestamp: DispatchTime,
        event: TouchEvent?
    ) {
        guard connectedDevices.contains(device), let session = sessions[device] else { return }
        session.receivedReports &+= 1
        session.lastReportAt = timestamp.uptimeNanoseconds
        if let event {
            handleTouchEvent(DeviceTouchEvent(device: device, touch: event))
            return
        }
        guard connectedDevices.contains(device) else { return }
        sessions[device]?.validator.recordRawReport(at: timestamp)
    }

    func handleTouchEvent(_ event: DeviceTouchEvent) {
        // Late queued reports must never resurrect a removed endpoint.
        guard connectedDevices.contains(event.device) else { return }
        guard let session = sessions[event.device] else { return }
        session.lifecycleEvents &+= 1
        session.lastEvent = event.touch
        session.inputDisposition = "received"
        guard !sleeping, !configurationPending else {
            session.inputDisposition = "topology_or_sleep_suspended"
            return
        }
        if !observationGate.isFresh {
            loseObservation(reason: "AppKit heartbeat expired")
            session.inputDisposition = "heartbeat_expired"
            return
        }

        let validation = session.validator.process(event.touch)
        session.validatedEvents &+= UInt64(validation.events.count)
        session.inputDisposition = validation.events.isEmpty ? "validator_waiting_or_filtered" : "validated"
        if let trigger = validation.stormStarted {
            suppressedUntilUp.remove(event.device)
            DriverLoggers.log(
                .warning,
                category: .gesture,
                "Touch storm detected on \(event.device.hexadecimalLocationID): \(trigger.rawValue). Entering confidence-tracking mode."
            )
            startStormRecoveryTimer(for: event.device)
        }

        if validation.cancelActiveGesture || validation.rejectedStream {
            session.gesture.forceCancel()
            if activeGestureDevice == event.device { activeGestureDevice = nil }
            cancelStuckGestureTimer()
            if challenge != nil {
                cancelPairingPresentation()
                scheduleDisplayReconciliation(reason: "Calibration interrupted by incoherent input")
            }
        }

        for touch in validation.events {
            routeValidatedTouchEvent(DeviceTouchEvent(device: event.device, touch: touch))
        }
    }

    private func routeValidatedTouchEvent(_ event: DeviceTouchEvent) {
        guard !configurationPending, !sleeping, !observationLost else { return }
        if calibrationPaused, authority[event.device]?.phase != .active { return }
        if suppressedUntilUp.contains(event.device) {
            if event.touch.kind == .up {
                suppressedUntilUp.remove(event.device)
            }
            return
        }

        if pairingTarget != nil, authority[event.device]?.phase != .active {
            guard sessions[event.device]?.validator.isStormActive == false else { return }
            handlePairingTouch(event)
            return
        }

        if sessions[event.device]?.mapperStore.currentMapper == nil {
            refreshDisplayMappings(reason: "touch without an active paired display")
            if pairingTarget != nil {
                handlePairingTouch(event)
                return
            }
        }

        guard authority[event.device]?.phase == .active, observationGate.allowsRouting,
              let session = sessions[event.device], session.mapperStore.currentMapper != nil else { return }

        if let activeGestureDevice, activeGestureDevice != event.device {
            DriverLoggers.log(.debug, category: .gesture, "Ignoring simultaneous contact from \(event.device.hexadecimalLocationID).")
            return
        }
        if event.touch.kind == .down {
            activeGestureDevice = event.device
        }

        session.gesture.handle(event.touch)
        if case .idle = session.gesture.state {
            if activeGestureDevice == event.device { activeGestureDevice = nil }
            cancelStuckGestureTimer()
        } else {
            scheduleStuckGestureTimer(for: event.device)
        }
    }

    private func ensureSession(for device: TouchDeviceIdentity) {
        guard sessions[device] == nil else { return }
        let mapperStore = CoordinateMapperStore()
        let gesture = GestureController(
            mapperProvider: { [mapperStore] in mapperStore.currentMapper },
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: focusRestorerProvider(),
            timing: GestureTiming(configuration: configuration.timing, gesture: configuration.gesture),
            doubleClickIntervalProvider: { NSEvent.doubleClickInterval },
            schedulingQueue: gestureQueue
        )
        gesture.mayRoute = { [weak self] in
            guard let self else { return false }
            return self.observationGate.allowsRouting && self.authority[device]?.phase == .active
        }
        gesture.onBecameIdle = { [weak self] in
            guard let self else { return }
            if self.activeGestureDevice == device { self.activeGestureDevice = nil }
            self.cancelStuckGestureTimer()
        }
        sessions[device] = DeviceTouchSession(
            mapperStore: mapperStore,
            gesture: gesture,
            validator: TouchStreamValidator()
        )
        authority[device] = PairingAuthority(phase: .waitingForHardware, reason: "Awaiting reconciliation", generation: generation)
    }

    func refreshDisplayMappings(reason: String) {
        guard !observationGate.isStopped, !sleeping, !configurationPending, !observationLost else { return }
        let observationRevision = observationGate.revision
        let activeDisplays = displayResolver.activeDisplays()
        if let previous = lastObservedDisplays, previous != activeDisplays {
            suspendRouting(reason: "Observed display topology changed")
            let oldDescriptors = previous.map { PairingEndpointDescriptor($0) }.sorted { $0.id < $1.id }
            let newDescriptors = activeDisplays.map { PairingEndpointDescriptor($0) }.sorted { $0.id < $1.id }
            if oldDescriptors != newDescriptors {
                do { try pairingStore.invalidateAmbiguous() }
                catch { DriverLoggers.log(.error, category: .display, "Could not persist topology revocation: \(error)") }
            }
        }
        lastObservedDisplays = activeDisplays
        do {
            let removedCount = try pairingStore.reconcileRuntimeDescriptors(
                connectedDevices: connectedDevices,
                displays: activeDisplays
            )
            if removedCount > 0 {
                DriverLoggers.log(
                    .notice,
                    category: .display,
                    "Removed \(removedCount) stale runtime pairing(s) after \(reason)."
                )
            }
        } catch {
            DriverLoggers.log(
                .error,
                category: .display,
                "Could not persist runtime pairing reconciliation: \(error.localizedDescription)"
            )
        }
        compatibleDisplays = displayResolver.matchingDisplays(from: activeDisplays)
        let resolvedDisplays = Dictionary(uniqueKeysWithValues: connectedDevices.compactMap { device in
            pairingStore.resolveDisplay(
                for: device,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            ).map { (device, $0) }
        })

        for device in connectedDevices {
            ensureSession(for: device)
            let display = resolvedDisplays[device]
            let mapper = display.map { CoordinateMapper(displayBounds: $0.bounds) }
            if mapper == nil, sessions[device]?.mapperStore.currentMapper != nil {
                sessions[device]?.gesture.forceCancel()
                sessions[device]?.validator.reset()
                sessions[device]?.cancelStormRecoveryTimer()
                if activeGestureDevice == device { activeGestureDevice = nil }
            }
            sessions[device]?.mapperStore.currentMapper = mapper
            if display != nil {
                setAuthority(device, phase: .active, reason: "Verified association and current endpoints")
            } else if calibrationPaused {
                setAuthority(device, phase: .suspended, reason: "Calibration cancelled; use re-pair to resume")
            } else if challenge != nil {
                setAuthority(device, phase: .calibrating, reason: "Touch and release both visible targets")
            } else {
                setAuthority(device, phase: .needsPairing, reason: "No verified association in this observation session")
            }
        }
        guard observationGate.resume(ifRevision: observationRevision) else {
            suspendRouting(reason: "Endpoint observation changed during reconciliation")
            scheduleDisplayReconciliation(reason: "Concurrent topology change")
            return
        }

        DriverLoggers.log(
            .notice,
            category: .display,
            "Display refresh after \(reason): \(compatibleDisplays.count) compatible display(s), \(connectedDevices.count) controller(s), \(resolvedDisplays.count) active pairing(s)."
        )
        beginPairingIfNeeded(resolvedDisplays: resolvedDisplays)
    }

    private func beginPairingIfNeeded(resolvedDisplays: [TouchDeviceIdentity: DisplaySnapshot]? = nil) {
        guard !calibrationPaused, !sleeping, !configurationPending, !observationLost else { return }
        if challenge != nil { return }
        let resolved = resolvedDisplays ?? Dictionary(uniqueKeysWithValues: connectedDevices.compactMap { device in
            pairingStore.resolveDisplay(
                for: device,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            ).map { (device, $0) }
        })
        let unresolved = connectedDevices
            .filter { resolved[$0] == nil }
            .sorted { $0.locationID < $1.locationID }

        let usedDisplayIDs = Set(resolved.values.map(\.displayID))
        let candidates = compatibleDisplays.filter { !usedDisplayIDs.contains($0.displayID) }

        guard !unresolved.isEmpty else {
            pairingTarget = nil
            overlayPresentationAttempt = 0
            resetPairingTopologyStability()
            pairingTopologyWaitDescription = nil
            pairingOverlay.hide()
            return
        }

        guard unresolved.count == candidates.count, let target = candidates.first else {
            for device in unresolved {
                setAuthority(device, phase: .waitingForHardware, reason: "Waiting for complete controller/display topology")
            }
            pairingTarget = nil
            overlayPresentationAttempt = 0
            resetPairingTopologyStability()
            pairingOverlay.hide()
            waitForPairingTopology(
                "Waiting for complete pairing topology: \(unresolved.count) unresolved controller(s), \(candidates.count) unused compatible display(s)."
            )
            return
        }

        let topologySignature = PairingTopologySignature(
            devices: connectedDevices,
            displays: compatibleDisplays
        )
        if pairingTopologySignature == topologySignature {
            stablePairingTopologyObservationCount += 1
        } else {
            pairingTopologySignature = topologySignature
            stablePairingTopologyObservationCount = 1
        }

        guard stablePairingTopologyObservationCount >= requiredStablePairingTopologyObservations else {
            pairingTarget = nil
            overlayPresentationAttempt = 0
            pairingOverlay.hide()
            waitForPairingTopology("Waiting for reconnect topology to remain stable before calibration.")
            return
        }
        pairingTopologyWaitDescription = nil

        let total = min(connectedDevices.count, compatibleDisplays.count)
        let step = min(resolved.count + 1, total)
        guard pairingOverlay.showTarget(on: target, step: step, total: total, targetIndex: 0) else {
            pairingTarget = nil
            schedulePairingOverlayRetry()
            return
        }

        overlayPresentationAttempt = 0
        pairingTarget = target
        challenge = PairingChallenge(readyAt: DispatchTime.now().uptimeNanoseconds, generation: generation)
        for device in unresolved { setAuthority(device, phase: .calibrating, reason: "Touch and release both visible targets") }
        DriverLoggers.log(.notice, category: .display, "Waiting for a raw touch on display ID \(target.displayID).")
    }

    private func handlePairingTouch(_ event: DeviceTouchEvent) {
        guard let target = pairingTarget, var challenge, challenge.generation == generation else { return }
        let observationRevision = observationGate.revision

        let existingDisplayIsActive = pairingStore.resolveDisplay(
            for: event.device,
            connectedDevices: connectedDevices,
            displays: compatibleDisplays
        ) != nil
        guard !existingDisplayIsActive else {
            DriverLoggers.log(.debug, category: .display, "Ignoring pairing touch from an already resolved controller.")
            return
        }

        let currentDisplays = displayResolver.activeDisplays()
        guard pairingOverlay.isReady(on: target), observationGate.allowsRouting,
              observationGate.revision == observationRevision,
              pairingTopologySignature == PairingTopologySignature(
                devices: connectedDevices, displays: displayResolver.matchingDisplays(from: currentDisplays)),
              lastObservedDisplays == currentDisplays else {
            suspendRouting(reason: "Calibration display changed")
            scheduleDisplayReconciliation(reason: "Calibration placement revalidation")
            return
        }
        let hadContact = challenge.hasContact
        let result = challenge.consume(event)
        self.challenge = challenge
        sessions[event.device]?.inputDisposition = challenge.decision
        if result != .waiting || !hadContact {
            DriverLoggers.log(.notice, category: .display,
                "Calibration input on \(event.device.hexadecimalLocationID), target \(challenge.targetIndex + 1): \(challenge.decision).")
        }
        switch result {
        case .waiting:
            if !hadContact, challenge.hasContact { armChallengeTimeout() }
            return
        case .rejected:
            cancelPairingPresentation()
            scheduleDisplayReconciliation(reason: "Calibration contact rejected; start again")
            return
        case .nextTarget:
            challengeTimeout?.cancel()
            challengeTimeout = nil
            let step = authority.values.filter { $0.phase == .active }.count + 1
            guard pairingOverlay.showTarget(on: target, step: step, total: compatibleDisplays.count, targetIndex: 1) else {
                cancelPairingPresentation()
                scheduleDisplayReconciliation(reason: "Second calibration target unavailable")
                return
            }
            self.challenge?.readyAt = DispatchTime.now().uptimeNanoseconds
            return
        case .complete: break
        }

        do {
            try pairingStore.assign(
                device: event.device,
                to: target,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            )
            guard observationGate.allowsRouting, observationGate.revision == observationRevision else {
                try pairingStore.remove(device: event.device)
                suspendRouting(reason: "Topology changed while saving calibration")
                scheduleDisplayReconciliation(reason: "Calibration commit interrupted")
                return
            }
            challengeTimeout?.cancel()
            self.challenge = nil
            pairingTarget = nil
            pairingOverlay.showConfirmation(on: target)
            DriverLoggers.log(.notice, category: .display, "Paired controller \(event.device.hexadecimalLocationID) to display ID \(target.displayID).")
            refreshSessionMapper(for: event.device, display: target)
            setAuthority(event.device, phase: .active, reason: "Two physical calibration targets verified")

            pairingAdvanceWork?.cancel()
            let expectedGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.beginPairingIfNeeded()
            }
            pairingAdvanceWork = work
            gestureQueue.asyncAfter(deadline: .now() + .milliseconds(650), execute: work)
        } catch {
            cancelPairingPresentation()
            setAuthority(event.device, phase: .suspended, reason: "Calibration could not be persisted")
            DriverLoggers.log(.fault, category: .display, "Could not persist touch pairing: \(error.localizedDescription)")
        }
    }

    private func refreshSessionMapper(for device: TouchDeviceIdentity, display: DisplaySnapshot) {
        ensureSession(for: device)
        sessions[device]?.mapperStore.currentMapper = CoordinateMapper(displayBounds: display.bounds)
    }

    private func scheduleStuckGestureTimer(for device: TouchDeviceIdentity) {
        cancelStuckGestureTimer()
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .milliseconds(configuration.timing.stuckGestureTimeoutMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out; forcing cleanup.")
            self.sessions[device]?.gesture.handleIdleTimeout()
            self.stuckGestureTimer = nil
        }
        timer.resume()
        stuckGestureTimer = timer
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimer?.setEventHandler {}
        stuckGestureTimer?.cancel()
        stuckGestureTimer = nil
    }

    private func startStormRecoveryTimer(for device: TouchDeviceIdentity) {
        guard let session = sessions[device], session.stormRecoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.handleStormRecoveryTick(for: device, at: .now())
        }
        session.stormRecoveryTimer = timer
        session.stormSummaryTickCount = 0
        timer.resume()
    }

    func handleStormRecoveryTick(for device: TouchDeviceIdentity, at timestamp: DispatchTime) {
        guard let session = sessions[device], session.validator.isStormActive else {
            sessions[device]?.cancelStormRecoveryTimer()
            return
        }

        if let recovery = session.validator.recoverIfQuiet(at: timestamp) {
            session.cancelStormRecoveryTimer()
            if recovery.cancelActiveGesture {
                session.gesture.forceCancel()
                if activeGestureDevice == device { activeGestureDevice = nil }
                cancelStuckGestureTimer()
            }
            let duration = Double(
                recovery.snapshot.lastReportAtNanoseconds - recovery.snapshot.startedAtNanoseconds
            ) / 1_000_000_000
            DriverLoggers.log(
                .notice,
                category: .gesture,
                String(
                    format: "Touch storm ended on %@ after %.2fs: reports=%d, accepted=%d, dropped=%d, recoveredContacts=%d. Returning to normal mode.",
                    device.hexadecimalLocationID,
                    duration,
                    recovery.snapshot.totalReports,
                    recovery.snapshot.acceptedSamples,
                    recovery.snapshot.droppedSamples,
                    recovery.snapshot.recoveredContacts
                )
            )
            return
        }

        session.stormSummaryTickCount += 1
        guard session.stormSummaryTickCount.isMultiple(of: 5),
              let snapshot = session.validator.stormSnapshot() else { return }
        let duration = Double(timestamp.uptimeNanoseconds - snapshot.startedAtNanoseconds) / 1_000_000_000
        DriverLoggers.log(
            .notice,
            category: .gesture,
            String(
                format: "Touch storm active on %@ for %.2fs: reports=%d, accepted=%d, dropped=%d, recoveredContacts=%d, tracking=%@.",
                device.hexadecimalLocationID,
                duration,
                snapshot.totalReports,
                snapshot.acceptedSamples,
                snapshot.droppedSamples,
                snapshot.recoveredContacts,
                snapshot.hasAcquiredTrack ? "yes" : "no"
            )
        )
    }

    func hasStormRecoveryTimer(for device: TouchDeviceIdentity) -> Bool {
        sessions[device]?.stormRecoveryTimer != nil
    }

    private func setAuthority(_ device: TouchDeviceIdentity, phase: PairingPhase, reason: String) {
        let previous = authority[device]
        authority[device] = PairingAuthority(phase: phase, reason: reason, generation: generation)
        if previous?.phase != phase || previous?.reason != reason {
            DriverLoggers.log(.notice, category: .display,
                             "Controller \(device.hexadecimalLocationID): \(phase.rawValue), \(reason), generation \(generation).")
        }
    }

    private func suspendRouting(reason: String) {
        observationGate.suspend()
        generation &+= 1
        reconciliationWork?.cancel()
        cancelPairingPresentation()
        for (device, session) in sessions {
            session.gesture.forceCancel()
            session.mapperStore.currentMapper = nil
            session.validator.reset()
            session.cancelStormRecoveryTimer()
            setAuthority(device, phase: .suspended, reason: reason)
        }
        activeGestureDevice = nil
        cancelStuckGestureTimer()
    }

    func loseObservation(reason: String) {
        guard !observationLost else { return }
        observationLost = true
        suspendRouting(reason: reason)
        do { try pairingStore.invalidateAmbiguous() }
        catch { DriverLoggers.log(.error, category: .display, "Could not persist observation revocation: \(error)") }
    }

    func resumeObservation() {
        observationGate.acknowledge()
        observationLost = false
        configurationPending = false
        sleeping = false
        refreshDisplayMappings(reason: "Observation resumed; ambiguous associations require calibration")
    }

    private func startObservation() {
        observationGate.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.observationGate.externalChange()
            self?.gestureQueue.async { [weak self] in
                self?.sleeping = true
                self?.loseObservation(reason: "System sleep interrupts endpoint observation")
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.gestureQueue.async { [weak self] in
                self?.loseObservation(reason: "System wake requires fresh endpoint observation")
                self?.resumeObservation()
            }
        })
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.sleeping else { return }
            if !self.observationGate.isFresh {
                self.loseObservation(reason: "AppKit observation gap")
            }
            if self.configurationPending,
               DispatchTime.now().uptimeNanoseconds - self.configurationStartedAt > 4_000_000_000 {
                self.loseObservation(reason: "Display transaction completion was not observed")
            }
            guard !self.heartbeatPending else { return }
            self.heartbeatPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                let gap = !self.observationGate.isFresh
                if gap { self.observationGate.externalChange() }
                self.observationGate.acknowledge()
                self.hidMonitor.reconcileDevices()
                self.gestureQueue.async { [weak self] in
                    guard let self else { return }
                    self.heartbeatPending = false
                    if gap { self.loseObservation(reason: "AppKit observation gap") }
                    if self.observationLost { self.resumeObservation() }
                    if !self.configurationPending,
                       self.lastObservedDisplays != self.displayResolver.activeDisplays() {
                        self.refreshDisplayMappings(reason: "Periodic topology inventory")
                    }
                }
            }
        }
        topologyPoll = timer
        timer.resume()
    }

    private func armChallengeTimeout() {
        challengeTimeout?.cancel()
        let expectedGeneration = generation
        let expectedReadyAt = challenge?.readyAt
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration, self.challenge?.hasContact == true,
                  self.challenge?.readyAt == expectedReadyAt else { return }
            self.cancelPairingPresentation()
            self.scheduleDisplayReconciliation(reason: "Calibration contact was not released; release fingers and retry")
        }
        challengeTimeout = work
        gestureQueue.asyncAfter(deadline: .now() + .seconds(2), execute: work)
    }

    func handleControlCommand(_ command: String) -> String {
        if !observationGate.isFresh { loseObservation(reason: "AppKit heartbeat expired") }
        switch command {
        case "status": break
        case "re-pair":
            suspendRouting(reason: "User requested physical re-pairing")
            do { try pairingStore.invalidateAll() }
            catch {
                calibrationPaused = true
                return json(["error": "Could not persist pairing reset: \(error.localizedDescription)"])
            }
            calibrationPaused = false
            // Reply before presentation work so the command does not wait for AppKit.
            scheduleDisplayReconciliation(reason: "Canonical re-pair command")
        case "cancel-pairing":
            calibrationPaused = true
            cancelPairingPresentation()
            for device in connectedDevices where authority[device]?.phase != .active {
                setAuthority(device, phase: .suspended, reason: "Calibration cancelled; use re-pair to resume")
            }
        default: return json(["error": "Unknown command"])
        }
        let records: [[String: Any]] = connectedDevices.sorted { $0.locationID < $1.locationID }.map { device in
            let current = authority[device]
            let display = pairingStore.resolveDisplay(for: device, connectedDevices: connectedDevices, displays: compatibleDisplays)
            var record: [String: Any] = [
                "controller": device.hexadecimalLocationID,
                "state": current?.phase.rawValue ?? "waitingForHardware",
                "reason": current?.reason ?? "No observation",
                "generation": current?.generation ?? generation
            ]
            if let session = sessions[device] {
                record["receivedReports"] = session.receivedReports
                record["lifecycleEvents"] = session.lifecycleEvents
                record["validatedEvents"] = session.validatedEvents
                record["inputDisposition"] = session.inputDisposition
                record["stormActive"] = session.validator.isStormActive
                if let timestamp = session.lastReportAt {
                    let now = DispatchTime.now().uptimeNanoseconds
                    record["lastReportAgeMs"] = now >= timestamp ? (now - timestamp) / 1_000_000 : 0
                }
                if let event = session.lastEvent {
                    record["lastEvent"] = ["kind": String(describing: event.kind), "rawX": event.rawX, "rawY": event.rawY]
                }
            }
            if let display, current?.phase == .active {
                record["displayID"] = display.displayID
                record["bounds"] = ["x": display.bounds.minX, "y": display.bounds.minY,
                                    "width": display.bounds.width, "height": display.bounds.height]
            }
            return record
        }
        return json(["pid": getpid(), "generation": generation, "controllers": records,
                     "calibrationPaused": calibrationPaused, "heartbeatFresh": observationGate.isFresh,
                     "routingGateOpen": observationGate.allowsRouting,
                     "target": pairingTarget?.displayID as Any? ?? NSNull(),
                     "targetStep": challenge.map { $0.targetIndex + 1 } as Any? ?? NSNull()])
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"Could not encode status\"}" }
        return text
    }

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayCallback else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        didRegisterDisplayCallback = result == .success
        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayCallback else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        _ = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
        didRegisterDisplayCallback = false
    }

    private func registerScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.observationGate.externalChange()
            self?.gestureQueue.async { [weak self] in
                guard let self else { return }
                self.suspendRouting(reason: "AppKit screen parameters changed")
                self.scheduleDisplayReconciliation(reason: "AppKit screen parameters changed")
            }
        }
    }

    private func unregisterScreenParametersObserver() {
        guard let screenParametersObserver else { return }
        NotificationCenter.default.removeObserver(screenParametersObserver)
        self.screenParametersObserver = nil
    }

    private func scheduleDisplayReconciliation(
        reason: String,
        delay: DispatchTimeInterval = .milliseconds(250)
    ) {
        gestureQueue.async { [weak self] in
            guard let self, !self.observationGate.isStopped else { return }
            self.overlayPresentationAttempt = 0
            self.reconciliationWork?.cancel()
            let expectedGeneration = self.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.refreshDisplayMappings(reason: reason)
            }
            self.reconciliationWork = work
            self.gestureQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func schedulePairingOverlayRetry() {
        guard overlayPresentationAttempt < 20 else {
            DriverLoggers.log(.error, category: .display, "Pairing overlay remained unavailable after bounded retries; waiting for the next display or HID event.")
            return
        }
        overlayPresentationAttempt += 1
        reconciliationWork?.cancel()
        let attempt = overlayPresentationAttempt
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.refreshDisplayMappings(reason: "pairing overlay readiness retry \(attempt)")
        }
        reconciliationWork = work
        gestureQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func waitForPairingTopology(_ description: String) {
        if pairingTopologyWaitDescription != description {
            DriverLoggers.log(.notice, category: .display, description)
            pairingTopologyWaitDescription = description
        }
        reconciliationWork?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.refreshDisplayMappings(reason: "pairing topology readiness retry")
        }
        reconciliationWork = work
        gestureQueue.asyncAfter(deadline: .now() + pairingTopologyRetryDelay, execute: work)
    }

    private func resetPairingTopologyStability() {
        pairingTopologySignature = nil
        stablePairingTopologyObservationCount = 0
    }

    private func cancelPairingPresentation() {
        challenge = nil
        for device in connectedDevices where authority[device]?.phase == .calibrating {
            setAuthority(device, phase: .needsPairing, reason: "Awaiting a fresh calibration presentation")
        }
        challengeTimeout?.cancel()
        challengeTimeout = nil
        pairingTarget = nil
        resetPairingTopologyStability()
        pairingTopologyWaitDescription = nil
        pairingAdvanceWork?.cancel()
        pairingAdvanceWork = nil
        pairingOverlay.hide()
    }

    private func installSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            ignoreDefaultSignalAction(signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            return source
        }
    }

    private func stopApplicationEventLoop() {
        guard isApplicationEventLoopRunning else { return }

        let stopAndWake = {
            NSApp.stop(nil)
            guard let wakeEvent = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) else { return }
            NSApp.postEvent(wakeEvent, atStart: false)
        }

        if Thread.isMainThread {
            stopAndWake()
        } else {
            DispatchQueue.main.async(execute: stopAndWake)
        }
    }

    private func verifySyntheticEventPermission() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        logPermissionIdentity()
        if CGRequestPostEventAccess() { return true }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if trusted || CGPreflightPostEventAccess() { return true }
        DriverLoggers.log(.fault, category: .lifecycle, "Synthetic mouse event permission is not granted. Grant Accessibility and restart the driver.")
        return false
    }

    private func logPermissionIdentity() {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
        let launcher = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"
        DriverLoggers.log(.error, category: .lifecycle, "Permission identity: executable=\(executable), launcher=\(launcher).")
    }

    private func ignoreDefaultSignalAction(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        _ = sigaction(signalNumber, &action, nil)
    }
}

/// Thread-safe gate shared with AppKit callbacks and delayed gesture work.
final class ObservationGate {
    private let lock = NSLock()
    private var suspended = false
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private var monitoring = false
    private let now: () -> UInt64
    private var acknowledgedAt: UInt64
    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        acknowledgedAt = now()
    }
    private var observationRevision: UInt64 = 0
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return observationRevision }
    var isFresh: Bool {
        lock.lock(); defer { lock.unlock() }
        return !monitoring || now() - acknowledgedAt < 4_000_000_000
    }
    var allowsRouting: Bool {
        lock.lock(); defer { lock.unlock() }
        return !suspended && (!monitoring || now() - acknowledgedAt < 4_000_000_000)
    }
    func start() { lock.lock(); monitoring = true; acknowledgedAt = now(); lock.unlock() }
    func acknowledge() { lock.lock(); acknowledgedAt = now(); lock.unlock() }
    func suspend() { lock.lock(); suspended = true; lock.unlock() }
    func stop() { lock.lock(); stopped = true; suspended = true; observationRevision &+= 1; lock.unlock() }
    func externalChange() {
        lock.lock(); suspended = true; observationRevision &+= 1; lock.unlock()
    }
    func resume(ifRevision expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, expected == observationRevision else { return false }
        suspended = false
        return true
    }
}

private struct PairingEndpointDescriptor: Equatable {
    let id: CGDirectDisplayID
    let runtimeIdentifier: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    init(_ display: DisplaySnapshot) {
        id = display.displayID; vendor = display.vendorNumber
        runtimeIdentifier = display.runtimeIdentifier
        model = display.modelNumber; serial = display.serialNumber
    }
}

private final class DeviceTouchSession {
    var receivedReports: UInt64 = 0
    var lifecycleEvents: UInt64 = 0
    var validatedEvents: UInt64 = 0
    var lastReportAt: UInt64?
    var lastEvent: TouchEvent?
    var inputDisposition = "no_reports_received"
    let mapperStore: CoordinateMapperStore
    let gesture: GestureController
    let validator: TouchStreamValidator
    var stormRecoveryTimer: DispatchSourceTimer?
    var stormSummaryTickCount = 0

    init(mapperStore: CoordinateMapperStore, gesture: GestureController, validator: TouchStreamValidator) {
        self.mapperStore = mapperStore
        self.gesture = gesture
        self.validator = validator
    }

    deinit {
        cancelStormRecoveryTimer()
    }

    func cancelStormRecoveryTimer() {
        stormRecoveryTimer?.setEventHandler {}
        stormRecoveryTimer?.cancel()
        stormRecoveryTimer = nil
        stormSummaryTickCount = 0
    }
}

private struct PairingTopologySignature: Equatable {
    let devices: [TouchDeviceIdentity]
    let displays: [PairingDisplaySignature]

    init(devices: Set<TouchDeviceIdentity>, displays: [DisplaySnapshot]) {
        self.devices = devices.sorted { lhs, rhs in
            if lhs.locationID != rhs.locationID { return lhs.locationID < rhs.locationID }
            return (lhs.serialNumber ?? "") < (rhs.serialNumber ?? "")
        }
        self.displays = displays.map(PairingDisplaySignature.init).sorted { lhs, rhs in
            lhs.displayID < rhs.displayID
        }
    }
}

private struct PairingDisplaySignature: Equatable {
    let displayID: CGDirectDisplayID
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    let bounds: CGRect

    init(_ display: DisplaySnapshot) {
        displayID = display.displayID
        vendorNumber = display.vendorNumber
        modelNumber = display.modelNumber
        serialNumber = display.serialNumber
        bounds = display.bounds
    }
}

private final class CoordinateMapperStore {
    private let lock = NSLock()
    private var storedMapper: CoordinateMapper?

    var currentMapper: CoordinateMapper? {
        get { lock.lock(); defer { lock.unlock() }; return storedMapper }
        set { lock.lock(); storedMapper = newValue; lock.unlock() }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, context in
    guard let context else { return }
    let app = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    app.handleDisplayReconfiguration(displayID: displayID, flags: flags)
}
