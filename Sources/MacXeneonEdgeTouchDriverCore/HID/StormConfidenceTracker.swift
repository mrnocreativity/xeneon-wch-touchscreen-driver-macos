import Foundation

/// Fixed-memory, per-controller evidence tracking. No timers, I/O or synthetic input.
struct StormConfidenceTracker {
    // Conservative initial defaults. Tune with captured traces, not aggregate counters.
    static let window: UInt64 = 160_000_000
    static let maximumGap: UInt64 = 48_000_000
    static let releaseConfirmation: UInt64 = 24_000_000
    static let capacity = 24
    private let minimumSpan: UInt64 = 48_000_000
    private let minimumSamples = 6
    private let minimumSupport = 0.70

    struct Output {
        var events: [TouchEvent] = []
        var cancel = false
        var completed = false
        var clean = false
        var reason = "collecting"
    }

    private struct Track {
        var samples: [TouchEvent]
        var pendingRelease: TouchEvent?
        var consecutiveOutliers = 0
        var clean = true
    }

    private var recent: [TouchEvent] = []
    private var track: Track?
    var hasTrack: Bool { track != nil }

    mutating func process(_ event: TouchEvent) -> Output {
        recent.append(event)
        let now = event.timestamp.uptimeNanoseconds
        recent.removeAll { now < $0.timestamp.uptimeNanoseconds || now - $0.timestamp.uptimeNanoseconds > Self.window }
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }

        guard var current = track else { return acquire(endingAt: event) }
        let last = current.samples.last!
        if event.kind == .up {
            // A release cannot establish confidence; only end an already supported path.
            if current.pendingRelease == nil,
               elapsed(last, event) <= Self.maximumGap,
               distance(last, event) <= 0.012,
               support(for: current.samples, excludingRelease: true) >= minimumSupport {
                current.pendingRelease = event
                track = current
                return Output(reason: "release_pending")
            }
        } else if plausible(event, following: current.samples) {
            // A pressed inlier during the confirmation window retracts a false release.
            let retracted = current.pendingRelease != nil
            current.pendingRelease = nil
            if retracted { current.clean = false }
            current.samples.append(event)
            if current.samples.count > Self.capacity { current.samples.removeFirst() }
            current.consecutiveOutliers = 0
            guard support(for: current.samples) >= minimumSupport else {
                return cancel(reason: "support_lost")
            }
            track = current
            let moved = event.rawX != last.rawX || event.rawY != last.rawY
            return Output(events: moved ? [withKind(event, .move)] : [],
                          reason: retracted ? "false_release_retracted" : "track_supported")
        }

        current.clean = false
        current.consecutiveOutliers += 1
        track = current
        if current.consecutiveOutliers >= 4 ||
            (current.pendingRelease == nil && elapsed(last, event) > Self.maximumGap) ||
            support(for: current.samples, excludingRelease: current.pendingRelease != nil) < minimumSupport {
            return cancel(reason: "contradictory_reports")
        }
        return Output(reason: "outlier")
    }

    mutating func advance(at timestamp: DispatchTime) -> Output {
        guard let current = track else { return Output(reason: "idle") }
        if let release = current.pendingRelease {
            guard age(release, at: timestamp) <= 250_000_000 else {
                return cancel(reason: "stale_release")
            }
            guard age(release, at: timestamp) >= Self.releaseConfirmation else {
                return Output(reason: "release_pending")
            }
            let last = current.samples.last!
            track = nil
            recent.removeAll(keepingCapacity: true)
            return Output(events: [TouchEvent(kind: .up, contactID: last.contactID,
                rawX: last.rawX, rawY: last.rawY, timestamp: release.timestamp)],
                completed: true, clean: current.clean, reason: "release_confirmed")
        }
        if age(current.samples.last!, at: timestamp) > Self.maximumGap {
            return cancel(reason: "track_expired")
        }
        return Output(reason: "track_supported")
    }

    func allowsHold(at timestamp: DispatchTime) -> Bool {
        guard let current = track, current.pendingRelease == nil,
              current.consecutiveOutliers == 0 else { return false }
        return age(current.samples.last!, at: timestamp) <= Self.maximumGap &&
            support(for: current.samples) >= minimumSupport
    }

    private mutating func cancel(reason: String) -> Output {
        track = nil
        recent.removeAll(keepingCapacity: true)
        return Output(cancel: true, reason: reason)
    }

    private mutating func acquire(endingAt event: TouchEvent) -> Output {
        guard event.kind != .up else { return Output(reason: "unowned_release") }
        // One bounded candidate per seed. Contradictions stay in the denominator.
        var candidates: [[Int]] = []
        for seed in recent.indices where recent[seed].kind != .up {
            var indices = [seed]
            var samples = [recent[seed]]
            for index in recent.indices where index > seed && recent[index].kind != .up {
                if plausible(recent[index], following: samples) {
                    indices.append(index)
                    samples.append(recent[index])
                }
            }
            candidates.append(indices)
        }
        candidates.sort { $0.count > $1.count }
        guard let winner = candidates.first,
              winner.count >= minimumSamples,
              winner.last == recent.count - 1,
              elapsed(recent[winner[0]], event) >= minimumSpan else {
            return Output(reason: "insufficient_evidence")
        }
        guard Double(winner.count) / Double(recent.count) >= minimumSupport else {
            return Output(reason: "low_support")
        }
        let selected = Set(winner)
        if candidates.dropFirst().contains(where: { candidate in
            candidate.filter { !selected.contains($0) }.count >= 3 &&
                Double(candidate.count) >= Double(winner.count) * 0.60
        }) {
            return Output(reason: "competing_path")
        }
        let samples = winner.map { recent[$0] }
        track = Track(samples: samples, clean: winner.count == recent.count)
        var output = [withKind(samples[0], .down)]
        for index in 1..<samples.count {
            if distance(samples[index - 1], samples[index]) > 0 {
                output.append(withKind(samples[index], .move))
            }
        }
        return Output(events: output, reason: "track_acquired")
    }

    private func support(for samples: [TouchEvent], excludingRelease: Bool = false) -> Double {
        let evidence = recent.filter { !excludingRelease || $0.kind != .up }
        guard !evidence.isEmpty else { return 0 }
        // Count exact accepted reports, not proximity to a centre that outliers can move.
        let accepted = Set(samples.map { $0.timestamp.uptimeNanoseconds })
        return Double(evidence.filter { accepted.contains($0.timestamp.uptimeNanoseconds) }.count) /
            Double(evidence.count)
    }

    private func plausible(_ event: TouchEvent, following samples: [TouchEvent]) -> Bool {
        guard let last = samples.last, event.contactID == last.contactID else { return false }
        let delta = elapsed(last, event)
        guard delta > 0, delta <= Self.maximumGap else { return false }
        let dt = Double(delta) / 1_000_000_000
        // Absolute safety cap; gaps/outliers cannot create an arbitrarily large gate.
        guard distance(last, event) <= min(0.06, 0.008 + 3 * dt) else { return false }
        guard samples.count >= 2 else { return true }
        let previous = samples[samples.count - 2]
        let previousDT = Double(elapsed(previous, last)) / 1_000_000_000
        guard previousDT > 0 else { return false }
        let a = point(previous), b = point(last), c = point(event)
        let dx = (b.0 - a.0) * dt / previousDT
        let dy = (b.1 - a.1) * dt / previousDT
        let predictionError = hypot(c.0 - b.0 - dx, c.1 - b.1 - dy)
        // Local prediction permits gradual turns and acceleration, not teleportation.
        let tolerance = min(0.025, 0.008 + 0.5 * hypot(dx, dy) + 30 * dt * dt)
        return predictionError <= tolerance
    }

    private func point(_ event: TouchEvent) -> (Double, Double) {
        (Double(event.rawX) / Double(XeneonEdgeDevice.rawXRange.upperBound),
         Double(event.rawY) / Double(XeneonEdgeDevice.rawYRange.upperBound))
    }

    private func distance(_ a: TouchEvent, _ b: TouchEvent) -> Double {
        let p = point(a), q = point(b)
        return hypot(q.0 - p.0, q.1 - p.1)
    }

    private func elapsed(_ a: TouchEvent, _ b: TouchEvent) -> UInt64 {
        age(a, at: b.timestamp)
    }

    private func age(_ event: TouchEvent, at timestamp: DispatchTime) -> UInt64 {
        let start = event.timestamp.uptimeNanoseconds, end = timestamp.uptimeNanoseconds
        return end >= start ? end - start : UInt64.max
    }

    private func withKind(_ event: TouchEvent, _ kind: TouchEvent.Kind) -> TouchEvent {
        TouchEvent(kind: kind, contactID: event.contactID, rawX: event.rawX,
                   rawY: event.rawY, timestamp: event.timestamp)
    }
}
