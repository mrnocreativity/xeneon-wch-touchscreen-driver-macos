import CoreGraphics
import Foundation

/// Queue-confined focus ownership and bounded activation, independent of AX.
final class WindowFocusTransaction<Window: Equatable> {
    private let focusedWindow: () -> Window?
    private let windowAtPoint: (CGPoint) -> Window?
    private let activate: (Window) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval
    private let timeout: TimeInterval
    private var generation: UInt64 = 0
    private var captured: Window?
    private var target: Window?
    private var initialFocus: Window?

    init(
        focusedWindow: @escaping () -> Window?,
        windowAtPoint: @escaping (CGPoint) -> Window?,
        activate: @escaping (Window) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timeout: TimeInterval = 0.25
    ) {
        self.focusedWindow = focusedWindow
        self.windowAtPoint = windowAtPoint
        self.activate = activate
        self.schedule = schedule
        self.now = now
        self.timeout = timeout
    }

    func capture(inheriting previous: WindowFocusTransaction<Window>? = nil) {
        let inherited = previous?.ownsFocus() == true ? previous?.captured : nil
        previous?.discard()
        cancelPreparation()
        initialFocus = focusedWindow()
        captured = inherited ?? initialFocus
        target = nil
    }

    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void) {
        cancelPreparation()
        let originalFocus = focusedWindow()
        // A continuation must not reclaim focus after the user changes windows.
        if let target, originalFocus != target {
            completion(false)
            return
        }
        if target == nil, let initialFocus, originalFocus != initialFocus {
            completion(false)
            return
        }
        guard let resolved = windowAtPoint(point) else {
            completion(false)
            return
        }
        target = resolved
        if originalFocus == resolved {
            completion(true)
            return
        }
        let attempt = generation
        let deadline = now() + timeout
        activate(resolved)

        func poll() {
            guard self.generation == attempt else { return }
            let current = self.focusedWindow()
            if self.now() >= deadline {
                completion(false)
            } else if current == resolved {
                completion(self.windowAtPoint(point) == resolved)
            } else if current != nil && current != originalFocus {
                completion(false)
            } else {
                self.schedule(0.01, poll)
            }
        }
        // Let native activation notifications run before delivering mouse input.
        schedule(0.015, poll)
    }

    func ownsFocus() -> Bool {
        guard let target else { return false }
        return focusedWindow() == target
    }

    func cancelPreparation() { generation &+= 1 }

    func restore(onFailure: @escaping () -> Void = {}) {
        cancelPreparation()
        let previous = captured
        let shouldRestore = ownsFocus()
        captured = nil
        target = nil
        initialFocus = nil
        if shouldRestore, let previous, focusedWindow() != previous {
            let attempt = generation
            let beforeRestore = focusedWindow()
            let deadline = now() + timeout
            activate(previous)
            func poll() {
                guard self.generation == attempt else { return }
                let current = self.focusedWindow()
                if current == previous { return }
                if self.now() >= deadline || (current != nil && current != beforeRestore) {
                    onFailure()
                } else {
                    self.schedule(0.01, poll)
                }
            }
            schedule(0.015, poll)
        }
    }

    func discard() {
        cancelPreparation()
        captured = nil
        target = nil
        initialFocus = nil
    }
}
