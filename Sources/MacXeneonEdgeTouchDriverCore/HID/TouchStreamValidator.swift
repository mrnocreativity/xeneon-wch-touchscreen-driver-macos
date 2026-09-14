import Foundation

/// Validates healthy contacts and extracts coherent finger tracks from a mixed storm stream.
public final class TouchStreamValidator {
    public enum StormTrigger: String, Equatable {
        case severeCoordinateJump = "severe coordinate jump"
        case repeatedFastSegments = "repeated implausibly fast segments"
        case chaoticProbationPath = "chaotic probation path"
        case overlappingContact = "overlapping contact transition"
        case outOfRangeCoordinate = "coordinate outside device range"
    }

    public struct Configuration: Equatable {
        public var probationNanoseconds: UInt64
        public var fastNormalizedSpeed: Double
        public var severeNormalizedSpeed: Double
        public var maximumProbationPathSpeed: Double
        public var minimumChaoticPathLength: Double
        public var maximumChaoticNetRatio: Double

        public static let defaults = Configuration(
            probationNanoseconds: 40_000_000,
            fastNormalizedSpeed: 10,
            severeNormalizedSpeed: 18,
            maximumProbationPathSpeed: 12,
            minimumChaoticPathLength: 0.20,
            maximumChaoticNetRatio: 0.45
        )

        public init(
            probationNanoseconds: UInt64,
            fastNormalizedSpeed: Double,
            severeNormalizedSpeed: Double,
            maximumProbationPathSpeed: Double,
            minimumChaoticPathLength: Double,
            maximumChaoticNetRatio: Double
        ) {
            self.probationNanoseconds = probationNanoseconds
            self.fastNormalizedSpeed = fastNormalizedSpeed
            self.severeNormalizedSpeed = severeNormalizedSpeed
            self.maximumProbationPathSpeed = maximumProbationPathSpeed
            self.minimumChaoticPathLength = minimumChaoticPathLength
            self.maximumChaoticNetRatio = maximumChaoticNetRatio
        }
    }

    public struct Result: Equatable {
        public let events: [TouchEvent]
        public let rejectedStream: Bool
        public let stormStarted: StormTrigger?
        public let cancelActiveGesture: Bool

        public init(
            events: [TouchEvent] = [],
            rejectedStream: Bool = false,
            stormStarted: StormTrigger? = nil,
            cancelActiveGesture: Bool = false
        ) {
            self.events = events
            self.rejectedStream = rejectedStream
            self.stormStarted = stormStarted
            self.cancelActiveGesture = cancelActiveGesture
        }
    }

    public struct StormSnapshot: Equatable {
        public let startedAtNanoseconds: UInt64
        public let lastReportAtNanoseconds: UInt64
        public let totalReports: Int
        public let acceptedSamples: Int
        public let droppedSamples: Int
        public let recoveredContacts: Int
        public let hasAcquiredTrack: Bool
    }

    public struct StormRecovery: Equatable {
        public let snapshot: StormSnapshot
        public let confirmedAtNanoseconds: UInt64
        public let cancelActiveGesture: Bool
    }

    private struct Candidate {
        let down: TouchEvent
        var last: TouchEvent
        var moves: [TouchEvent] = []
        var pathLength = 0.0
        var fastSegmentCount = 0
    }

    private struct Accepted {
        var last: TouchEvent
        var pendingFastMove: TouchEvent?
    }

    private enum NormalState {
        case idle
        case candidate(Candidate)
        case accepted(Accepted)
    }

    private struct StormState {
        let startedAtNanoseconds: UInt64
        var lastReportAtNanoseconds: UInt64
        var totalReports: Int
        var acceptedSamples = 0
        var droppedSamples = 0
        var recoveredContacts = 0
        var tracker = StormConfidenceTracker()
    }

    private enum State {
        case normal(NormalState)
        case storm(StormState)
    }

    private let configuration: Configuration
    private var state: State = .normal(.idle)
    private var probationTracker = StormConfidenceTracker()
    public private(set) var isRecoveryProbation = false
    private var cleanRecoveryContacts = 0
    public private(set) var lastDecision = "normal"
    private var trace: [DiagnosticSample] = []
    private var traceCursor = 0
    private var incidentTrace: [DiagnosticSample]?
    private var lastDiagnosticAt: UInt64?
    private var lastProcessedAt: UInt64?

    public struct DiagnosticSample: Codable, Equatable {
        public let uptimeNanoseconds: UInt64
        public let kind: String
        public let x: Int?
        public let y: Int?
        public let decision: String
        public let emitted: Int
        public let cancelled: Bool
    }

    public var needsConfidenceTimer: Bool {
        if case .storm = state { return true }
        return isRecoveryProbation && probationTracker.hasTrack
    }

    public var hasConfidenceContact: Bool {
        if case .storm(let storm) = state { return storm.tracker.hasTrack }
        return isRecoveryProbation && probationTracker.hasTrack
    }

    public func allowsHold(at timestamp: DispatchTime = .now()) -> Bool {
        if case .storm(let storm) = state { return storm.tracker.allowsHold(at: timestamp) }
        return !isRecoveryProbation || probationTracker.allowsHold(at: timestamp)
    }

    /// Ordered fixed-size capture, including pre-trigger evidence. Encoding/I/O belongs off input queue.
    public func diagnosticSamples() -> [DiagnosticSample] {
        guard trace.count == 256 else { return trace }
        return Array(trace[traceCursor...]) + Array(trace[..<traceCursor])
    }

    /// At most one snapshot per 30 seconds per controller, including short burst storms.
    public func takeDiagnosticCapture(at timestamp: DispatchTime) -> [DiagnosticSample]? {
        let now = timestamp.uptimeNanoseconds
        if let lastDiagnosticAt,
           elapsedNanoseconds(from: lastDiagnosticAt, to: now) < 30_000_000_000 { return nil }
        lastDiagnosticAt = now
        let capture = incidentTrace ?? diagnosticSamples()
        incidentTrace = nil
        return capture
    }

    private func recordDiagnostic(_ event: TouchEvent?, at timestamp: DispatchTime, result: Result,
                                  timer: Bool = false) {
        let sample = DiagnosticSample(uptimeNanoseconds: timestamp.uptimeNanoseconds,
            kind: event.map { String(describing: $0.kind) } ?? (timer ? "timer" : "raw_idle"),
            x: event?.rawX, y: event?.rawY, decision: lastDecision,
            emitted: result.events.count, cancelled: result.cancelActiveGesture || result.rejectedStream)
        if trace.count < 256 { trace.append(sample) }
        else { trace[traceCursor] = sample; traceCursor = (traceCursor + 1) % 256 }
        if let count = incidentTrace?.count, count < 256 { incidentTrace?.append(sample) }
    }

    public init(configuration: Configuration = .defaults) {
        self.configuration = configuration
    }

    public var isStormActive: Bool {
        if case .storm = state { return true }
        return false
    }

    public func reset() {
        state = .normal(.idle)
        probationTracker = StormConfidenceTracker()
        isRecoveryProbation = false
        cleanRecoveryContacts = 0
        lastProcessedAt = nil
    }

    /// Records a valid raw HID report that did not create a lifecycle event.
    public func recordRawReport(at timestamp: DispatchTime) {
        noteRawReport(at: timestamp)
        lastDecision = "raw_idle"
        recordDiagnostic(nil, at: timestamp, result: Result())
    }

    public func process(_ event: TouchEvent) -> Result {
        let now = event.timestamp.uptimeNanoseconds
        guard !(isStormActive || isRecoveryProbation) || (lastProcessedAt.map({ now > $0 }) ?? true) else {
            lastDecision = "unordered_report"
            let cancelled = cancelConfidenceContact()
            recordDiagnostic(event, at: event.timestamp, result: cancelled)
            return cancelled
        }
        lastProcessedAt = now
        noteRawReport(at: event.timestamp)
        guard XeneonEdgeDevice.rawXRange.contains(event.rawX), XeneonEdgeDevice.rawYRange.contains(event.rawY) else {
            let result: Result
            if isStormActive {
                lastDecision = "out_of_range"
                result = cancelConfidenceContact()
            } else {
                result = beginStorm(trigger: .outOfRangeCoordinate, at: event, cancelActiveGesture: true)
            }
            recordDiagnostic(event, at: event.timestamp, result: result)
            return result
        }
        let result: Result
        switch state {
        case .normal(let normal):
            if isRecoveryProbation {
                let output = probationTracker.process(event)
                lastDecision = output.reason
                if output.cancel || output.reason == "low_support" || output.reason == "competing_path" {
                    cleanRecoveryContacts = 0
                    result = beginStorm(trigger: .chaoticProbationPath, at: event, cancelActiveGesture: true)
                } else {
                    result = Result(events: output.events)
                }
            } else {
                lastDecision = "normal_validation"
                result = processNormal(event, state: normal)
            }
        case .storm(var storm):
            let output = storm.tracker.process(event)
            lastDecision = output.reason
            if output.reason == "track_supported" || output.reason == "track_acquired" {
                storm.acceptedSamples += 1
            } else if output.reason != "release_pending" {
                storm.droppedSamples += 1
            }
            state = .storm(storm)
            result = Result(events: output.events, cancelActiveGesture: output.cancel)
        }
        recordDiagnostic(event, at: event.timestamp, result: result)
        return result
    }

    /// Timer-driven release confirmation and stale-track cancellation, never timeout-to-tap.
    public func advanceConfidence(at timestamp: DispatchTime) -> Result {
        let output: StormConfidenceTracker.Output
        if case .storm(var storm) = state {
            output = storm.tracker.advance(at: timestamp)
            if output.completed { storm.recoveredContacts += 1 }
            state = .storm(storm)
        } else if isRecoveryProbation {
            output = probationTracker.advance(at: timestamp)
            if output.completed {
                cleanRecoveryContacts = output.clean ? cleanRecoveryContacts + 1 : 0
                if cleanRecoveryContacts >= 3 {
                    isRecoveryProbation = false
                    state = .normal(.idle)
                }
            }
            if output.cancel { cleanRecoveryContacts = 0 }
        } else { return Result() }
        lastDecision = output.reason
        let result = Result(events: output.events, cancelActiveGesture: output.cancel)
        if output.completed || output.cancel {
            recordDiagnostic(nil, at: timestamp, result: result, timer: true)
        }
        return result
    }

    /// Revoke in-flight contacts without erasing a controller's noise history.
    public func cancelConfidenceContact() -> Result {
        if case .storm(var storm) = state {
            storm.tracker = StormConfidenceTracker()
            state = .storm(storm)
        } else {
            probationTracker = StormConfidenceTracker()
            state = .normal(.idle)
        }
        return Result(cancelActiveGesture: true)
    }

    public func stormSnapshot() -> StormSnapshot? {
        guard case .storm(let storm) = state else { return nil }
        return snapshot(for: storm)
    }

    /// Raw silence ends the active incident, but stricter contact probation remains.
    public func recoverIfQuiet(
        at timestamp: DispatchTime,
        quietNanoseconds: UInt64 = 1_000_000_000
    ) -> StormRecovery? {
        guard case .storm(let storm) = state else { return nil }
        let now = timestamp.uptimeNanoseconds
        guard elapsedNanoseconds(from: storm.lastReportAtNanoseconds, to: now) >= quietNanoseconds else {
            return nil
        }

        let recovery = StormRecovery(
            snapshot: snapshot(for: storm),
            confirmedAtNanoseconds: now,
            cancelActiveGesture: storm.tracker.hasTrack
        )
        state = .normal(.idle)
        isRecoveryProbation = true
        probationTracker = StormConfidenceTracker()
        cleanRecoveryContacts = 0
        return recovery
    }

    private func noteRawReport(at timestamp: DispatchTime) {
        guard case .storm(var storm) = state else { return }
        storm.lastReportAtNanoseconds = max(storm.lastReportAtNanoseconds, timestamp.uptimeNanoseconds)
        storm.totalReports += 1
        state = .storm(storm)
    }

    private func processNormal(_ event: TouchEvent, state normal: NormalState) -> Result {
        switch normal {
        case .idle:
            guard event.kind != .up else { return Result() }
            // The HID parser may still consider the raw contact pressed when a
            // storm ends. Treat its next pressed sample as a fresh candidate.
            let down = eventWithKind(event, .down)
            state = .normal(.candidate(Candidate(down: down, last: down)))
            return Result()

        case .candidate(var candidate):
            switch event.kind {
            case .down:
                return beginStorm(trigger: .overlappingContact, at: event, cancelActiveGesture: false)

            case .move:
                let speed = normalizedSpeed(from: candidate.last, to: event)
                candidate.pathLength += normalizedDistance(from: candidate.last, to: event)
                candidate.last = event
                candidate.moves.append(event)
                if speed >= configuration.fastNormalizedSpeed {
                    candidate.fastSegmentCount += 1
                }
                if speed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: false)
                }
                if candidate.fastSegmentCount >= 2 {
                    return beginStorm(trigger: .repeatedFastSegments, at: event, cancelActiveGesture: false)
                }

                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                guard elapsed >= configuration.probationNanoseconds else {
                    state = .normal(.candidate(candidate))
                    return Result()
                }
                guard probationIsPlausible(candidate, elapsedNanoseconds: elapsed) else {
                    return beginStorm(trigger: .chaoticProbationPath, at: event, cancelActiveGesture: false)
                }

                state = .normal(.accepted(Accepted(last: event)))
                return Result(events: [candidate.down] + meaningfulMoves(candidate.moves, after: candidate.down))

            case .up:
                let releaseSpeed = normalizedSpeed(from: candidate.last, to: event)
                if releaseSpeed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: false)
                }
                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                guard candidate.fastSegmentCount == 0,
                      probationIsPlausible(candidate, elapsedNanoseconds: elapsed) else {
                    return beginStorm(trigger: .chaoticProbationPath, at: event, cancelActiveGesture: false)
                }
                state = .normal(.idle)
                let up = eventAtCoordinates(event, of: candidate.last, kind: .up)
                return Result(events: [candidate.down] + meaningfulMoves(candidate.moves, after: candidate.down) + [up])
            }

        case .accepted(var accepted):
            switch event.kind {
            case .down:
                return beginStorm(trigger: .overlappingContact, at: event, cancelActiveGesture: true)

            case .move:
                let speed = normalizedSpeed(from: accepted.last, to: event)
                if speed >= configuration.severeNormalizedSpeed ||
                    (speed >= configuration.fastNormalizedSpeed && accepted.pendingFastMove != nil) {
                    let trigger: StormTrigger = speed >= configuration.severeNormalizedSpeed
                        ? .severeCoordinateJump
                        : .repeatedFastSegments
                    return beginStorm(trigger: trigger, at: event, cancelActiveGesture: true)
                }
                if speed >= configuration.fastNormalizedSpeed {
                    accepted.pendingFastMove = event
                    state = .normal(.accepted(accepted))
                    return Result()
                }

                accepted.pendingFastMove = nil
                let moved = event.rawX != accepted.last.rawX || event.rawY != accepted.last.rawY
                accepted.last = event
                state = .normal(.accepted(accepted))
                return Result(events: moved ? [event] : [])

            case .up:
                let speed = normalizedSpeed(from: accepted.last, to: event)
                if speed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: true)
                }
                let last = accepted.last
                state = .normal(.idle)
                return Result(events: [eventAtCoordinates(event, of: last, kind: .up)])
            }
        }
    }

    private func beginStorm(
        trigger: StormTrigger,
        at event: TouchEvent,
        cancelActiveGesture: Bool
    ) -> Result {
        let timestamp = event.timestamp.uptimeNanoseconds
        lastDecision = "storm_trigger: \(trigger.rawValue)"
        if incidentTrace == nil { incidentTrace = Array(diagnosticSamples().suffix(64)) }
        isRecoveryProbation = false
        probationTracker = StormConfidenceTracker()
        cleanRecoveryContacts = 0
        state = .storm(StormState(
            startedAtNanoseconds: timestamp,
            lastReportAtNanoseconds: timestamp,
            totalReports: 1
        ))
        return Result(
            rejectedStream: true,
            stormStarted: trigger,
            cancelActiveGesture: cancelActiveGesture
        )
    }

    private func meaningfulMoves(_ moves: [TouchEvent], after initial: TouchEvent) -> [TouchEvent] {
        var last = initial
        return moves.compactMap { move in
            defer { last = move }
            guard move.rawX != last.rawX || move.rawY != last.rawY else { return nil }
            return eventWithKind(move, .move)
        }
    }

    private func probationIsPlausible(_ candidate: Candidate, elapsedNanoseconds: UInt64) -> Bool {
        guard candidate.moves.isEmpty == false else { return true }
        let elapsedSeconds = max(Double(elapsedNanoseconds) / 1_000_000_000, 0.000_001)
        if candidate.pathLength / elapsedSeconds > configuration.maximumProbationPathSpeed {
            return false
        }
        let netDistance = normalizedDistance(from: candidate.down, to: candidate.last)
        if candidate.pathLength >= configuration.minimumChaoticPathLength,
           netDistance / candidate.pathLength < configuration.maximumChaoticNetRatio {
            return false
        }
        return true
    }

    private func snapshot(for storm: StormState) -> StormSnapshot {
        StormSnapshot(
            startedAtNanoseconds: storm.startedAtNanoseconds,
            lastReportAtNanoseconds: storm.lastReportAtNanoseconds,
            totalReports: storm.totalReports,
            acceptedSamples: storm.acceptedSamples,
            droppedSamples: storm.droppedSamples,
            recoveredContacts: storm.recoveredContacts,
            hasAcquiredTrack: storm.tracker.hasTrack
        )
    }

    private func eventWithKind(_ event: TouchEvent, _ kind: TouchEvent.Kind) -> TouchEvent {
        TouchEvent(
            kind: kind,
            contactID: event.contactID,
            rawX: event.rawX,
            rawY: event.rawY,
            timestamp: event.timestamp
        )
    }

    private func eventAtCoordinates(
        _ event: TouchEvent,
        of coordinates: TouchEvent,
        kind: TouchEvent.Kind
    ) -> TouchEvent {
        TouchEvent(
            kind: kind,
            contactID: event.contactID,
            rawX: coordinates.rawX,
            rawY: coordinates.rawY,
            timestamp: event.timestamp
        )
    }

    private func normalizedSpeed(from start: TouchEvent, to end: TouchEvent) -> Double {
        let elapsed = elapsedNanoseconds(from: start, to: end)
        guard elapsed > 0 else {
            return normalizedDistance(from: start, to: end) == 0 ? 0 : .infinity
        }
        return normalizedDistance(from: start, to: end) / (Double(elapsed) / 1_000_000_000)
    }

    private func normalizedDistance(from start: TouchEvent, to end: TouchEvent) -> Double {
        let width = Double(XeneonEdgeDevice.rawXRange.upperBound - XeneonEdgeDevice.rawXRange.lowerBound)
        let height = Double(XeneonEdgeDevice.rawYRange.upperBound - XeneonEdgeDevice.rawYRange.lowerBound)
        let deltaX = Double(end.rawX - start.rawX) / width
        let deltaY = Double(end.rawY - start.rawY) / height
        return hypot(deltaX, deltaY)
    }

    private func elapsedNanoseconds(from start: TouchEvent, to end: TouchEvent) -> UInt64 {
        elapsedNanoseconds(from: start.timestamp.uptimeNanoseconds, to: end.timestamp.uptimeNanoseconds)
    }

    private func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}
