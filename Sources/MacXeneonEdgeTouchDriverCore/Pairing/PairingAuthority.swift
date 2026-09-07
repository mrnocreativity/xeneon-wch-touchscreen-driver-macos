import CoreGraphics
import Foundation

enum PairingPhase: String, Codable {
    case waitingForHardware, needsPairing, calibrating, active, suspended
}

struct PairingAuthority {
    var phase: PairingPhase
    var reason: String
    var generation: UInt64
}

/// Two fresh target contacts, measured in panel-local normalized coordinates.
/// No synthetic pointer position is used to infer which device was touched.
struct PairingChallenge {
    static let targets = [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)]
    enum Result { case waiting, nextTarget, complete, rejected }
    private(set) var targetIndex = 0
    private(set) var device: TouchDeviceIdentity?
    private var contactStarted: UInt64?
    var readyAt: UInt64
    let generation: UInt64

    init(readyAt: UInt64, generation: UInt64) {
        self.readyAt = readyAt
        self.generation = generation
    }

    mutating func consume(_ event: DeviceTouchEvent) -> Result {
        let touch = event.touch
        guard touch.timestamp.uptimeNanoseconds > readyAt else { return .waiting }
        if let device, device != event.device { return .rejected }
        let point = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
            .map(rawX: touch.rawX, rawY: touch.rawY)
        let target = Self.targets[targetIndex]
        guard abs(point.x - target.x) <= 0.08, abs(point.y - target.y) <= 0.12 else {
            return .rejected
        }
        switch touch.kind {
        case .down:
            guard contactStarted == nil else { return .rejected }
            device = event.device
            contactStarted = touch.timestamp.uptimeNanoseconds
            return .waiting
        case .move:
            guard let start = contactStarted else { return .waiting }
            guard touch.timestamp.uptimeNanoseconds >= start else { return .rejected }
            return touch.timestamp.uptimeNanoseconds - start <= 2_000_000_000 ? .waiting : .rejected
        case .up:
            guard let start = contactStarted else { return .waiting }
            guard touch.timestamp.uptimeNanoseconds >= start else { return .rejected }
            let duration = touch.timestamp.uptimeNanoseconds - start
            guard duration >= 30_000_000, duration <= 2_000_000_000 else { return .rejected }
            contactStarted = nil
            if targetIndex == 1 { return .complete }
            targetIndex = 1
            return .nextTarget
        }
    }
}
