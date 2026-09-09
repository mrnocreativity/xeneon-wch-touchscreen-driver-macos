import Foundation

/// Saturated diagnostics drop file copies instead of blocking input or growing
/// without bound. Unified logging remains available through DriverLoggers.
final class BoundedDiagnosticQueue {
    private let queue = DispatchQueue(label: "touch.file-log", qos: .utility)
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var dropped: UInt64 = 0

    init(capacity: Int = 512) { slots = DispatchSemaphore(value: max(1, capacity)) }
    var droppedCount: UInt64 { lock.lock(); defer { lock.unlock() }; return dropped }

    func submit(_ operation: @escaping () -> Void) {
        guard slots.wait(timeout: .now()) == .success else {
            lock.lock(); dropped &+= 1; lock.unlock()
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            operation()
        }
    }

    func flush() { queue.sync {} }
}
