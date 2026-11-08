import AppKit
import CoreGraphics

/// Identifies connected screens before a touch controller is mapped to any of them.
final class TouchscreenChooser: NSObject, NSWindowDelegate {
    private struct Row {
        let id: CGDirectDisplayID
        let number: Int
        let checkbox: NSButton
        let badge: NSPanel
        let label: NSTextField
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
        guard eligible.isSubset(of: Set(visible.map { $0.0.displayID })) else { return false }
        self.completion = completion
        requiredCount = count

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
            let (badge, label) = makeBadge(for: screen)
            rows.append(Row(id: display.displayID, number: number, checkbox: checkbox, badge: badge, label: label))
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
        let listHeight = CGFloat(min(max(visible.count, 1), 7) * 28 + 8)
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 450, height: listHeight + 155),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Touchscreen Setup"
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
        for row in rows { row.badge.orderFrontRegardless() }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func makeBadge(for screen: NSScreen) -> (NSPanel, NSTextField) {
        let frame = CGRect(x: screen.visibleFrame.midX - 34, y: screen.visibleFrame.maxY - 64, width: 68, height: 48)
        let badge = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        badge.level = .floating
        badge.ignoresMouseEvents = true
        badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.frame = CGRect(x: 0, y: 10, width: 68, height: 28)
        badge.contentView?.addSubview(label)
        badge.setFrame(frame, display: true)
        return (badge, label)
    }

    @objc private func selectionChanged() {
        confirmButton?.isEnabled = rows.filter { $0.checkbox.state == .on }.count == requiredCount
        for row in rows {
            let selected = row.checkbox.state == .on
            row.badge.backgroundColor = selected ? .systemGreen : .darkGray
            row.label.stringValue = selected ? "\(row.number) ✓" : "\(row.number)"
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
        for row in rows { row.badge.orderOut(nil) }
        rows.removeAll()
        confirmButton = nil
        completion = nil
    }
}
