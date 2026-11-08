import AppKit
import CoreGraphics

/// Identifies connected screens before a touch controller is mapped to any of them.
final class TouchscreenChooser: NSObject, NSWindowDelegate {
    private struct Row {
        let id: CGDirectDisplayID
        let checkbox: NSButton
        let overlay: NSPanel
        let badge: DisplayNumberBadge
    }

    private var panel: NSPanel?
    private var rows: [Row] = []
    private var confirmButton: NSButton?
    private var requiredCount = 0
    private var completion: ((Set<CGDirectDisplayID>?) -> Void)?

    func show(
        from displays: [DisplaySnapshot], eligible: Set<CGDirectDisplayID>, count: Int,
        completion: @escaping (Set<CGDirectDisplayID>?) -> Void
    ) -> Bool {
        hide()
        let screens = NSScreen.screens
        let arranged = displays.sorted(by: DisplayResolver.isBeforeInArrangement)
        let visible = arranged.compactMap { display -> (DisplaySnapshot, NSScreen)? in
            guard let screen = screens.first(where: { PairingOverlayController.displayID(for: $0) == display.displayID }),
                  CGDisplayIsActive(display.displayID) != 0,
                  CGDisplayVendorNumber(display.displayID) == display.vendorNumber,
                  CGDisplayModelNumber(display.displayID) == display.modelNumber,
                  CGDisplayBounds(display.displayID) == display.bounds else { return nil }
            return (display, screen)
        }
        let mainDisplayID = CGMainDisplayID()
        guard eligible.isSubset(of: Set(visible.map { $0.0.displayID })),
              let mainScreen = screens.first(where: { PairingOverlayController.displayID(for: $0) == mainDisplayID })
        else { return false }
        self.completion = completion
        requiredCount = count

        let frame = mainScreen.visibleFrame
        let maxVisibleRows = max(1, min(7, Int((frame.height - 310) / 28)))
        let listHeight = CGFloat(min(max(visible.count, 1), maxVisibleRows) * 28 + 8)
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 450, height: listHeight + 155),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setFrameOrigin(CGPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))

        let heading = NSTextField(labelWithString: "Choose your touchscreens")
        heading.font = .boldSystemFont(ofSize: 17)
        let instruction = NSTextField(wrappingLabelWithString: count == 1
            ? "A supported touch controller is ready. Use your mouse or trackpad to select its display below."
            : "Supported touch controllers are ready. Use your mouse or trackpad to select their \(count) displays below.")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, entry) in visible.enumerated() {
            let (display, screen) = entry
            let number = index + 1
            let checkbox = NSButton(checkboxWithTitle: "\(number). \(screen.localizedName)",
                                    target: self, action: #selector(selectionChanged))
            checkbox.isEnabled = eligible.contains(display.displayID)
            list.addArrangedSubview(checkbox)
            let (overlay, badge) = makeOverlay(for: screen, number: number,
                                               chooserFrame: display.displayID == mainDisplayID ? window.frame : nil)
            rows.append(Row(id: display.displayID, checkbox: checkbox, overlay: overlay, badge: badge))
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = NSView()
        document.addSubview(list)
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 3),
            list.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: "Continue", target: self, action: #selector(acceptSelection))
        confirm.keyEquivalent = "\r"
        confirmButton = confirm
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.spacing = 10
        let stack = NSStackView(views: [heading, instruction, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.title = "Touchscreen Setup"
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.delegate = self
        guard let content = window.contentView else { hide(); return false }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: listHeight)
        ])
        panel = window
        selectionChanged()
        for row in rows {
            row.overlay.orderFrontRegardless()
            guard PairingOverlayController.displayID(for: row.overlay.screen) == row.id else {
                hide()
                return false
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func makeOverlay(for screen: NSScreen, number: Int, chooserFrame: CGRect?) -> (NSPanel, DisplayNumberBadge) {
        let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false, screen: screen)
        overlay.level = .floating
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView()
        var diameter = min(220, min(screen.frame.width, screen.frame.height) * 0.38)
        var centerOffset: CGFloat = 0
        if let chooserFrame {
            // Keep the main display's badge above its centered chooser.
            let gap: CGFloat = 16
            diameter = min(diameter, max(1, screen.visibleFrame.maxY - chooserFrame.maxY - 2 * gap))
            centerOffset = screen.frame.midY - (chooserFrame.maxY + gap + diameter / 2)
        }
        let badge = DisplayNumberBadge(number: number, diameter: diameter)
        badge.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: diameter),
            badge.heightAnchor.constraint(equalTo: badge.widthAnchor),
            badge.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: centerOffset)
        ])
        TouchscreenOverlayBackdrop.install(in: overlay, content: content)
        overlay.setFrame(screen.frame, display: true)
        return (overlay, badge)
    }

    @objc private func selectionChanged() {
        confirmButton?.isEnabled = rows.filter { $0.checkbox.state == .on }.count == requiredCount
        for row in rows {
            row.badge.update(selected: row.checkbox.state == .on)
        }
    }

    @objc private func acceptSelection() {
        let selection = Set(rows.filter { $0.checkbox.state == .on }.map(\.id))
        guard selection.count == requiredCount else { return }
        finish(selection)
    }

    @objc private func cancelSelection() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ selection: Set<CGDirectDisplayID>?) {
        let callback = completion
        hide()
        callback?(selection)
    }

    func hide() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        for row in rows { row.overlay.orderOut(nil) }
        rows.removeAll()
        confirmButton = nil
        completion = nil
    }
}

private final class DisplayNumberBadge: NSView {
    private let label: NSTextField

    init(number: Int, diameter: CGFloat) {
        label = NSTextField(labelWithString: String(number))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 3
        label.font = .monospacedDigitSystemFont(ofSize: diameter * 0.53, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selected: Bool) {
        let green = NSColor(srgbRed: 0, green: 0.67, blue: 0.22, alpha: 1)
        layer?.backgroundColor = (selected ? green : .black).cgColor
        layer?.borderColor = (selected ? green : .white).cgColor
    }
}
