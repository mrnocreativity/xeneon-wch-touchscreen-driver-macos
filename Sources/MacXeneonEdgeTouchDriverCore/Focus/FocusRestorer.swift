import Foundation
import CoreGraphics

/// Captures and restores the focused window around a touch gesture.
public protocol FocusRestorer: AnyObject {
    /// Captures the currently focused window, if one is available.
    func captureFocusedWindow()

    /// Restores the captured focused window and clears the capture.
    func restoreCapturedWindow()

    /// Clears any captured focused window without restoring it.
    func discardCapturedWindow()

    /// Completes inline or on callbackQueue, after the exact touched window has focus.
    func prepareTarget(at point: CGPoint, callbackQueue: DispatchQueue, completion: @escaping (Bool) -> Void)

    /// Whether the prepared target still owns focus. Never activates a window.
    func isTargetFocused() -> Bool

    /// Invalidates unfinished activation work without injecting input.
    func cancelTargetPreparation()
}

public extension FocusRestorer {
    func prepareTarget(at point: CGPoint, callbackQueue: DispatchQueue, completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func isTargetFocused() -> Bool { true }

    func cancelTargetPreparation() {}
}

/// Focus restorer used by tests and non-production wiring.
public final class NoOpFocusRestorer: FocusRestorer {
    public init() {}

    public func captureFocusedWindow() {}

    public func restoreCapturedWindow() {}

    public func discardCapturedWindow() {}
}
