import AppKit
import ApplicationServices
import Foundation

/// Activates and restores exact windows through documented AppKit and AX APIs.
public final class AXFocusRestorer: FocusRestorer {
    private static weak var activeSession: AXFocusRestorer?
    private struct Window: Equatable {
        let application: AXUIElement
        let window: AXUIElement
        let processIdentifier: pid_t

        static func == (lhs: Window, rhs: Window) -> Bool {
            lhs.processIdentifier == rhs.processIdentifier && CFEqual(lhs.window, rhs.window)
        }
    }

    private let systemWideElement: AXUIElement
    // All transaction state and AppKit work live on the main queue.
    private lazy var transaction = WindowFocusTransaction<Window>(
        focusedWindow: { [weak self] in self?.focusedWindow() },
        windowAtPoint: { [weak self] in self?.window(at: $0) },
        activate: { [weak self] in self?.activate($0) },
        schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
    )

    public init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.systemWideElement = systemWideElement
        AXUIElementSetMessagingTimeout(systemWideElement, 0.05)
    }

    public func captureFocusedWindow() {
        onMain {
            // Transfer the original focus when another controller still owns a tap sequence.
            let previous = Self.activeSession
            self.transaction.capture(inheriting: previous !== self ? previous?.transaction : nil)
            Self.activeSession = self
        }
    }

    public func prepareTarget(at point: CGPoint, callbackQueue: DispatchQueue, completion: @escaping (Bool) -> Void) {
        onMain {
            self.transaction.prepare(at: point) { success in
                if !success {
                    DriverLoggers.log(.warning, category: .focus, "Touched window could not acquire verified focus; cancelling touch input.")
                }
                callbackQueue.async { completion(success) }
            }
        }
    }

    public func isTargetFocused() -> Bool {
        if Thread.isMainThread { return transaction.ownsFocus() }
        return DispatchQueue.main.sync { self.transaction.ownsFocus() }
    }

    public func cancelTargetPreparation() {
        onMain { self.transaction.cancelPreparation() }
    }

    public func restoreCapturedWindow() {
        onMain {
            self.transaction.restore {
                DriverLoggers.log(.warning, category: .focus, "Could not verify restoration of the previously focused window.")
            }
        }
    }

    public func discardCapturedWindow() {
        onMain { self.transaction.discard() }
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private func focusedWindow() -> Window? {
        guard let application = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute),
              let window = copyElementAttribute(application, attribute: kAXFocusedWindowAttribute) else { return nil }
        return makeWindow(application: application, window: window)
    }

    private func window(at point: CGPoint) -> Window? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let isWindow = roleResult == .success && (role as? String) == kAXWindowRole
        guard let window = isWindow ? element : copyElementAttribute(element, attribute: kAXWindowAttribute) else { return nil }
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(window, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        AXUIElementSetMessagingTimeout(window, 0.05)
        return Window(application: application, window: window, processIdentifier: processIdentifier)
    }

    private func makeWindow(application: AXUIElement, window: AXUIElement) -> Window? {
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(application, &processIdentifier) == .success else { return nil }
        return Window(application: application, window: window, processIdentifier: processIdentifier)
    }

    private func activate(_ target: Window) {
        _ = NSRunningApplication(processIdentifier: target.processIdentifier)?.activate(options: [])
        AXUIElementSetAttributeValue(target.application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.application, kAXFocusedWindowAttribute as CFString, target.window)
        AXUIElementSetAttributeValue(target.application, kAXMainWindowAttribute as CFString, target.window)
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
