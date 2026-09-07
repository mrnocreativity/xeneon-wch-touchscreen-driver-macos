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

/// One fresh target contact, measured in panel-local normalized coordinates.
/// No synthetic pointer position is used to infer which device was touched.
struct PairingChallenge {
    static let target = CGPoint(x: 0.5, y: 0.5)
    enum Result { case waiting, complete, rejected }
    private(set) var device: TouchDeviceIdentity?
    private var contactStarted: UInt64?
    var hasContact: Bool { contactStarted != nil }
    private(set) var decision = "waiting_for_fresh_contact"
    var readyAt: UInt64
    let generation: UInt64

    init(readyAt: UInt64, generation: UInt64) {
        self.readyAt = readyAt
        self.generation = generation
    }

    mutating func consume(_ event: DeviceTouchEvent) -> Result {
        let touch = event.touch
        guard touch.timestamp.uptimeNanoseconds > readyAt else {
            decision = "contact_predates_visible_target"
            return .waiting
        }
        if let device, device != event.device {
            decision = "competing_controller"
            return .rejected
        }
        let point = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
            .map(rawX: touch.rawX, rawY: touch.rawY)
        let target = Self.target
        guard abs(point.x - target.x) <= 0.08, abs(point.y - target.y) <= 0.12 else {
            decision = "outside_target"
            return .rejected
        }
        switch touch.kind {
        case .down:
            guard contactStarted == nil else { decision = "overlapping_contact"; return .rejected }
            device = event.device
            contactStarted = touch.timestamp.uptimeNanoseconds
            decision = "waiting_for_release"
            return .waiting
        case .move:
            guard let start = contactStarted else { decision = "move_without_fresh_down"; return .waiting }
            guard touch.timestamp.uptimeNanoseconds >= start else { return .rejected }
            return touch.timestamp.uptimeNanoseconds - start <= 2_000_000_000 ? .waiting : .rejected
        case .up:
            guard let start = contactStarted else { decision = "release_without_fresh_down"; return .waiting }
            guard touch.timestamp.uptimeNanoseconds >= start else { return .rejected }
            let duration = touch.timestamp.uptimeNanoseconds - start
            guard duration >= 30_000_000, duration <= 2_000_000_000 else {
                decision = "contact_duration_out_of_range"
                return .rejected
            }
            contactStarted = nil
            decision = "target_confirmed"
            return .complete
        }
    }
}
