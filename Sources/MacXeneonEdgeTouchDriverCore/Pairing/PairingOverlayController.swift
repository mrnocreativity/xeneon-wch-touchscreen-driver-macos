import AppKit
import CoreGraphics
import Foundation

/// UI boundary used by the pairing coordinator and its tests.
public protocol PairingOverlayPresenting: AnyObject {
    @discardableResult
    func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool
    func chooseDisplays(
        from displays: [DisplaySnapshot], eligible: Set<CGDirectDisplayID>, count: Int,
        completion: @escaping (Set<CGDirectDisplayID>?) -> Void
    ) -> Bool
    func explainVerification(completion: @escaping (Bool) -> Void)
    func isReady(on display: DisplaySnapshot) -> Bool
    func showConfirmation(on display: DisplaySnapshot)
    func hide()
}

public extension PairingOverlayPresenting {
    func chooseDisplays(
        from displays: [DisplaySnapshot], eligible: Set<CGDirectDisplayID>, count: Int,
        completion: @escaping (Set<CGDirectDisplayID>?) -> Void
    ) -> Bool { false }
    func explainVerification(completion: @escaping (Bool) -> Void) { completion(true) }
}

/// Native full-screen pairing overlay.
public final class PairingOverlayController: PairingOverlayPresenting {
    private var window: NSWindow?
    private let chooser = TouchscreenChooser()

    public init() {}

    @discardableResult
    public func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool {
        present(
            on: display,
            title: "Touch and release the circle",
            detail: "Display \(step) of \(total)",
            target: PairingChallenge.target
        )
    }

    public func isReady(on display: DisplaySnapshot) -> Bool {
        runOnMainReturning { [weak self] in
            guard let window = self?.window, window.isVisible,
                  CGDisplayIsActive(display.displayID) != 0,
                  Self.displayID(for: window.screen) == display.displayID,
                  let screen = window.screen else { return false }
            let current = Self.snapshot(for: display.displayID)
            return PairingOverlayGeometry.snapshotsMatch(display, current) &&
                PairingOverlayGeometry.framesMatch(window.frame, screen.frame)
        }
    }

    public func chooseDisplays(
        from displays: [DisplaySnapshot], eligible: Set<CGDirectDisplayID>, count: Int,
        completion: @escaping (Set<CGDirectDisplayID>?) -> Void
    ) -> Bool {
        runOnMainReturning {
            self.window?.orderOut(nil)
            self.window = nil
            return self.chooser.show(from: displays, eligible: eligible, count: count, completion: completion)
        }
    }

    public func showConfirmation(on display: DisplaySnapshot) {
        _ = present(on: display, title: "Paired", detail: "Touch input is assigned to this display")
    }

    public func explainVerification(completion: @escaping (Bool) -> Void) {
        runOnMain { self.chooser.explainVerification(completion: completion) }
    }

    public func hide() {
        runOnMain { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.chooser.hide()
        }
    }

    private func present(on display: DisplaySnapshot, title: String, detail: String, target: CGPoint? = nil) -> Bool {
        runOnMainReturning { [weak self] in
            let screens = NSScreen.screens
            let mainDisplayID = CGMainDisplayID()
            guard let self,
                  let primaryScreen = Self.screen(for: mainDisplayID, in: screens),
                  let screen = Self.screen(for: display.displayID, in: screens) else {
                DriverLoggers.log(.error, category: .display, "Could not present pairing overlay for display \(display.displayID).")
                return false
            }

            guard CGDisplayIsActive(display.displayID) != 0 else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "Target display \(display.displayID) is no longer active; presentation will retry."
                )
                return false
            }

            let currentDisplay = Self.snapshot(for: display.displayID)
            guard PairingOverlayGeometry.snapshotsMatch(display, currentDisplay) else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "CoreGraphics state changed before presenting on display \(display.displayID); presentation will retry."
                )
                return false
            }

            let expectedFrame = PairingOverlayGeometry.appKitFrame(
                for: currentDisplay.bounds,
                primaryCoreGraphicsFrame: CGDisplayBounds(mainDisplayID),
                primaryAppKitFrame: primaryScreen.frame
            )
            guard PairingOverlayGeometry.framesMatch(screen.frame, expectedFrame) else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "AppKit screen geometry is not ready for display \(display.displayID); expected \(expectedFrame), received \(screen.frame)."
                )
                return false
            }

            self.window?.orderOut(nil)

            let window = NSWindow(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
            TouchscreenOverlayBackdrop.install(in: window, content: PairingOverlayView(title: title, detail: detail, target: target))
            window.setFrame(expectedFrame, display: true)

            guard Self.displayID(for: window.screen) == display.displayID,
                  PairingOverlayGeometry.framesMatch(window.frame, expectedFrame) else {
                DriverLoggers.log(
                    .warning,
                    category: .display,
                    "Pairing overlay moved away from target display \(display.displayID); presentation will retry."
                )
                window.orderOut(nil)
                return false
            }

            self.window = window
            window.orderFrontRegardless()
            guard window.isVisible, Self.displayID(for: window.screen) == display.displayID,
                  PairingOverlayGeometry.framesMatch(window.frame, expectedFrame) else {
                window.orderOut(nil)
                self.window = nil
                return false
            }
            return true
        }
    }

    private static func screen(
        for displayID: CGDirectDisplayID,
        in screens: [NSScreen]
    ) -> NSScreen? {
        screens.first { Self.displayID(for: $0) == displayID }
    }

    static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func snapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: displayID,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID)
        )
    }

    private func runOnMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }

    private func runOnMainReturning<T>(_ operation: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return operation()
        }
        return DispatchQueue.main.sync(execute: operation)
    }
}

/// Pure coordinate conversion and comparison used to validate AppKit readiness.
enum PairingOverlayGeometry {
    static func snapshotsMatch(
        _ expected: DisplaySnapshot,
        _ current: DisplaySnapshot
    ) -> Bool {
        expected.displayID == current.displayID &&
            expected.vendorNumber == current.vendorNumber &&
            expected.modelNumber == current.modelNumber &&
            expected.serialNumber == current.serialNumber &&
            expected.pixelsWide == current.pixelsWide &&
            expected.pixelsHigh == current.pixelsHigh &&
            framesMatch(expected.bounds, current.bounds)
    }

    static func appKitFrame(
        for coreGraphicsFrame: CGRect,
        primaryCoreGraphicsFrame: CGRect,
        primaryAppKitFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: primaryAppKitFrame.minX + coreGraphicsFrame.minX - primaryCoreGraphicsFrame.minX,
            y: primaryAppKitFrame.maxY - (coreGraphicsFrame.maxY - primaryCoreGraphicsFrame.minY),
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )
    }

    static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}

enum TouchscreenOverlayBackdrop {
    static func install(in window: NSWindow, content: NSView) {
        window.backgroundColor = .clear
        window.isOpaque = false

        let blur = NSVisualEffectView()
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        window.contentView = blur

        let shade = NSView(frame: blur.bounds)
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.38).cgColor
        blur.addSubview(shade)

        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
    }
}

enum TouchscreenTargetStyle {
    static func apply(to layer: CALayer, edge: NSColor, fill: NSColor?) {
        layer.backgroundColor = fill?.cgColor
        layer.borderColor = edge.cgColor
        layer.borderWidth = 3
        layer.shadowColor = edge.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 9
        layer.shadowOffset = .zero
    }
}

private final class PairingOverlayView: NSView {
    private let titleText: String
    private let detailText: String
    private let target: CGPoint?
    private let circle = NSView()

    init(title: String, detail: String, target: CGPoint?) {
        self.titleText = title
        self.detailText = detail
        self.target = target
        super.init(frame: .zero)
        if target != nil {
            circle.wantsLayer = true
            addSubview(circle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
        ]

        drawCentered(titleText, atY: bounds.height - 70, attributes: titleAttributes)
        drawCentered(detailText, atY: bounds.height - 112, attributes: detailAttributes)
    }

    override func layout() {
        super.layout()
        guard let target else { return }
        let radius: CGFloat = 30
        circle.frame = CGRect(
            x: bounds.width * target.x - radius,
            y: bounds.height * (1 - target.y) - radius,
            width: radius * 2,
            height: radius * 2
        )
        if let layer = circle.layer {
            layer.cornerRadius = radius
            TouchscreenTargetStyle.apply(to: layer, edge: .white, fill: nil)
            let inset = layer.borderWidth / 2
            let outline = CGPath(ellipseIn: layer.bounds.insetBy(dx: inset, dy: inset), transform: nil)
            layer.shadowPath = outline.copy(strokingWithWidth: layer.borderWidth, lineCap: .butt,
                                            lineJoin: .round, miterLimit: 0)
        }
    }

    private func drawCentered(
        _ text: String,
        atY y: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: y - size.height / 2),
            withAttributes: attributes
        )
    }
}
