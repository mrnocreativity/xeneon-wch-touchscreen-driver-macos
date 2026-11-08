import AppKit
import CoreGraphics

/// Identifies connected screens before a touch controller is mapped to any of them.
final class TouchscreenChooser: NSObject, NSWindowDelegate {
    private struct Row {
        let id: CGDirectDisplayID
        let choice: DisplayChoiceRow
        let overlay: NSPanel
        let badgeWindow: NSPanel
        let badge: DisplayNumberBadge
    }

    private var panel: NSPanel?
    private var introduction: NSPanel?
    private var rows: [Row] = []
    private var confirmButton: NSButton?
    private var requiredCount = 0
    private var completion: ((Set<CGDirectDisplayID>?) -> Void)?
    private var verificationCompletion: ((Bool) -> Void)?
    private let setupSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

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
        let rowPitch = 46
        let maxVisibleRows = max(1, min(7, Int((frame.height - 310) / CGFloat(rowPitch))))
        let listHeight = CGFloat(min(max(visible.count, 1), maxVisibleRows) * rowPitch + 2)
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 450, height: listHeight + 155),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setFrameOrigin(CGPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))

        let heading = NSTextField(labelWithString: "Mark which displays are touchscreens")
        heading.font = .boldSystemFont(ofSize: 17)
        let instruction = NSTextField(wrappingLabelWithString: count == 1
            ? "Use your mouse or trackpad to select one display. Click its number on the screen or use the list below. Touch input is off until pairing."
            : "Use your mouse or trackpad to select \(count) displays. Click their numbers on the screens or use the list below. Touch input is off until pairing.")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, entry) in visible.enumerated() {
            let (display, screen) = entry
            let number = index + 1
            let choice = DisplayChoiceRow(number: number, name: screen.localizedName,
                                          available: eligible.contains(display.displayID))
            choice.target = self
            choice.action = #selector(selectionChanged)
            choice.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(choice)
            NSLayoutConstraint.activate([
                choice.widthAnchor.constraint(equalTo: list.widthAnchor),
                choice.heightAnchor.constraint(equalToConstant: 40)
            ])
            let (overlay, badgeWindow, badge) = makeOverlay(
                for: screen, number: number, enabled: choice.isEnabled,
                chooserFrame: display.displayID == mainDisplayID ? window.frame : nil
            )
            rows.append(Row(id: display.displayID, choice: choice, overlay: overlay,
                            badgeWindow: badgeWindow, badge: badge))
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = DisplayListView()
        document.addSubview(list)
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 3),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -3),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        let confirm = NSButton(title: "Continue", target: self, action: #selector(acceptSelection))
        confirmButton = confirm
        let buttons = actionButtons(in: window, primary: confirm)
        window.initialFirstResponder = rows.first(where: { $0.choice.isEnabled })?.choice
        let stack = NSStackView(views: [heading, instruction, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.title = "Touchscreen Setup"
        window.level = .modalPanel
        window.hidesOnDeactivate = false
        window.collectionBehavior = setupSpaces
        window.isReleasedWhenClosed = false
        window.delegate = self
        guard let content = window.contentView else { hide(); return false }
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: listHeight),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        panel = window
        selectionChanged()
        return showPrompt(
            on: frame, title: "Identify which displays are touchscreens",
            detail: "On the next screen, use your mouse or trackpad to mark the displays that have touch input.",
            nextAction: #selector(showDisplays)
        )
    }

    func explainVerification(completion: @escaping (Bool) -> Void) {
        hide()
        guard let screen = NSScreen.screens.first(where: {
            PairingOverlayController.displayID(for: $0) == CGMainDisplayID()
        }) else { completion(false); return }
        verificationCompletion = completion
        if !showPrompt(
            on: screen.visibleFrame, title: "Verify your touchscreens",
            detail: "After clicking Next, tap and release the circle on the touchscreen with your finger. The screen updates once the driver verifies the touch. Repeat for each touchscreen if prompted.",
            nextAction: #selector(beginVerification)
        ) {
            completion(false)
        }
    }

    private func showPrompt(on frame: CGRect, title: String, detail message: String, nextAction: Selector) -> Bool {
        let intro = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 450, height: 164),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        intro.title = "Touchscreen Setup"
        intro.level = .modalPanel
        intro.hidesOnDeactivate = false
        intro.collectionBehavior = setupSpaces
        intro.isReleasedWhenClosed = false
        intro.delegate = self
        intro.setFrameOrigin(CGPoint(x: frame.midX - intro.frame.width / 2, y: frame.midY - intro.frame.height / 2))
        let introHeading = NSTextField(labelWithString: title)
        introHeading.font = .boldSystemFont(ofSize: 17)
        let detail = NSTextField(wrappingLabelWithString: message)
        let next = NSButton(title: "Next", target: self, action: nextAction)
        let buttons = actionButtons(in: intro, primary: next)
        intro.initialFirstResponder = next
        let introStack = NSStackView(views: [introHeading, detail])
        introStack.orientation = .vertical
        introStack.alignment = .leading
        introStack.spacing = 12
        introStack.translatesAutoresizingMaskIntoConstraints = false
        guard let introContent = intro.contentView else { hide(); return false }
        introContent.addSubview(introStack)
        introContent.addSubview(buttons)
        NSLayoutConstraint.activate([
            introStack.leadingAnchor.constraint(equalTo: introContent.leadingAnchor, constant: 20),
            introStack.trailingAnchor.constraint(equalTo: introContent.trailingAnchor, constant: -20),
            introStack.topAnchor.constraint(equalTo: introContent.topAnchor, constant: 18),
            detail.widthAnchor.constraint(equalTo: introStack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: introStack.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: introContent.bottomAnchor, constant: -18)
        ])
        introduction = intro
        NSApp.activate(ignoringOtherApps: true)
        intro.makeKeyAndOrderFront(nil)
        guard intro.isVisible else { hide(); return false }
        return true
    }

    private func actionButtons(in window: NSWindow, primary: NSButton) -> NSStackView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.keyEquivalent = "\u{1b}"
        primary.keyEquivalent = "\r"
        window.defaultButtonCell = primary.cell as? NSButtonCell
        let buttons = NSStackView(views: [cancel, primary])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        return buttons
    }

    @objc private func showDisplays() {
        guard let window = panel, let introduction else { return }
        introduction.delegate = nil
        introduction.orderOut(nil)
        self.introduction = nil
        for row in rows {
            row.overlay.orderFrontRegardless()
            row.badgeWindow.orderFrontRegardless()
            guard PairingOverlayController.displayID(for: row.overlay.screen) == row.id,
                  PairingOverlayController.displayID(for: row.badgeWindow.screen) == row.id else {
                finish(nil)
                return
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard window.isVisible, PairingOverlayController.displayID(for: window.screen) == CGMainDisplayID() else {
            finish(nil)
            return
        }
    }

    private func makeOverlay(
        for screen: NSScreen, number: Int, enabled: Bool, chooserFrame: CGRect?
    ) -> (NSPanel, NSPanel, DisplayNumberBadge) {
        let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false, screen: screen)
        overlay.level = .floating
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = setupSpaces
        let content = NSView()
        let gap: CGFloat = 16
        let instructionHeight: CGFloat = 44
        var diameter = min(220, min(screen.frame.width, screen.frame.height) * 0.38)
        var badgeBottom = screen.frame.midY - diameter / 2
        if let chooserFrame {
            badgeBottom = chooserFrame.maxY + gap
            diameter = min(diameter, max(1, screen.visibleFrame.maxY - badgeBottom - instructionHeight - gap))
        }
        let instruction = NSTextField(wrappingLabelWithString: enabled
            ? "Click the number with your mouse or trackpad.\nTouch input is off until pairing."
            : "This display is already assigned.")
        instruction.alignment = .center
        instruction.textColor = .white
        instruction.font = .systemFont(ofSize: 14, weight: .medium)
        content.addSubview(instruction)
        TouchscreenOverlayBackdrop.install(in: overlay, content: content)
        overlay.setFrame(screen.frame, display: true)
        instruction.frame = CGRect(x: 12, y: badgeBottom - screen.frame.minY + diameter + 8,
                                   width: screen.frame.width - 24, height: instructionHeight - 8)

        // Keep the full-display blur click-through. Only the number receives clicks.
        let badgeWindow = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false, screen: screen)
        badgeWindow.level = .floating
        badgeWindow.backgroundColor = .clear
        badgeWindow.isOpaque = false
        badgeWindow.hasShadow = false
        badgeWindow.becomesKeyOnlyIfNeeded = true
        badgeWindow.ignoresMouseEvents = !enabled
        badgeWindow.collectionBehavior = setupSpaces
        let badge = DisplayNumberBadge(number: number, diameter: diameter)
        badge.target = self
        badge.action = #selector(toggleDisplay(_:))
        badge.isEnabled = enabled
        let glowMargin: CGFloat = 16
        let badgeContent = NSView()
        badge.setFrameOrigin(CGPoint(x: glowMargin, y: glowMargin))
        badgeContent.addSubview(badge)
        badgeWindow.contentView = badgeContent
        let badgeFrame = CGRect(x: screen.frame.midX - diameter / 2, y: badgeBottom,
                                width: diameter, height: diameter)
        badgeWindow.setFrame(badgeFrame.insetBy(dx: -glowMargin, dy: -glowMargin), display: true)
        return (overlay, badgeWindow, badge)
    }

    @objc private func toggleDisplay(_ sender: DisplayNumberBadge) {
        guard let row = rows.first(where: { $0.badge === sender }), row.choice.isEnabled else { return }
        row.choice.state = row.choice.state == .on ? .off : .on
        selectionChanged()
    }

    @objc private func selectionChanged() {
        confirmButton?.isEnabled = rows.filter { $0.choice.state == .on }.count == requiredCount
        for row in rows {
            row.choice.updateAppearance()
            row.badge.update(selected: row.choice.state == .on)
        }
    }

    @objc private func acceptSelection() {
        let selection = Set(rows.filter { $0.choice.state == .on }.map(\.id))
        guard selection.count == requiredCount else { return }
        finish(selection)
    }

    @objc private func beginVerification() { finishVerification(true) }

    @objc private func cancelSelection() {
        if verificationCompletion != nil { finishVerification(false) }
        else { finish(nil) }
    }
    func windowWillClose(_ notification: Notification) { cancelSelection() }

    private func finishVerification(_ confirmed: Bool) {
        let callback = verificationCompletion
        hide()
        callback?(confirmed)
    }

    private func finish(_ selection: Set<CGDirectDisplayID>?) {
        let callback = completion
        hide()
        callback?(selection)
    }

    func hide() {
        introduction?.delegate = nil
        introduction?.orderOut(nil)
        introduction = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        for row in rows {
            row.badgeWindow.orderOut(nil)
            row.overlay.orderOut(nil)
        }
        rows.removeAll()
        confirmButton = nil
        completion = nil
        verificationCompletion = nil
    }
}

private final class DisplayListView: NSView {
    override var isFlipped: Bool { true }
}

private final class DisplayChoiceRow: NSButton {
    private let numberLabel: NSTextField
    private let nameLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")

    init(number: Int, name: String, available: Bool) {
        numberLabel = NSTextField(labelWithString: String(number))
        nameLabel = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        isEnabled = available
        setAccessibilityLabel("Display \(number), \(name)")
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        numberLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let labels = NSStackView(views: [numberLabel, nameLabel, statusLabel])
        labels.spacing = 8
        labels.alignment = .centerY
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 26)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        let selected = state == .on
        let accent = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? accent.withAlphaComponent(0.14) : .controlBackgroundColor).cgColor
            layer?.borderColor = (selected ? accent : .separatorColor).cgColor
        }
        numberLabel.textColor = selected ? accent : .secondaryLabelColor
        nameLabel.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = isEnabled ? (selected ? "Selected" : "") : "Already assigned"
        setAccessibilityValue(isEnabled ? (selected ? "Selected" : "Unselected") : "Already assigned")
    }
}

private final class DisplayNumberBadge: NSButton {
    init(number: Int, diameter: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isBordered = false
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.53, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: String(number), attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        setAccessibilityLabel("Select display \(number)")
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(selected: Bool) {
        if let layer {
            let green = NSColor(srgbRed: 0, green: 0.67, blue: 0.22, alpha: 1)
            TouchscreenTargetStyle.apply(to: layer, edge: selected ? green : .white, fill: selected ? green : .black)
        }
        setAccessibilityValue(selected ? "Selected" : "Unselected")
    }
}
