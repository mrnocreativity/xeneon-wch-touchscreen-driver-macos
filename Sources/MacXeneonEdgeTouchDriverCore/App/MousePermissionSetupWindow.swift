import AppKit

/// Guides the user through missing mouse-event access and confirms startup.
final class MousePermissionSetupWindow: NSObject, NSWindowDelegate {
    private let checkAccess: () -> Bool
    private let requestAccess: @Sendable () -> Void
    private let onGranted: () -> Void
    private let onQuit: () -> Void
    private let onDone: () -> Void
    private var didRequestAccess = false
    private(set) var didCompleteSetup = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 470, height: 210),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    init(
        checkAccess: @escaping () -> Bool,
        requestAccess: @escaping @Sendable () -> Void,
        onGranted: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.checkAccess = checkAccess
        self.requestAccess = requestAccess
        self.onGranted = onGranted
        self.onQuit = onQuit
        self.onDone = onDone
        super.init()

        window.title = "Xeneon Touchscreen Driver Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "Mouse-event permission required")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "The driver turns touches into mouse clicks and other mouse events. It cannot provide touch control until you grant access."
        )
        status.stringValue =
            "In System Settings → Privacy & Security, allow MacXeneonEdgeTouchDriver under Device Control and Data Access (Accessibility on earlier macOS). Then click Check Again."
        status.textColor = .secondaryLabelColor

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitSetup))
        quit.keyEquivalent = "\u{1b}"
        let check = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        let settings = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        settings.keyEquivalent = "\r"
        let buttons = NSStackView(views: [quit, check, settings])
        buttons.spacing = 8

        setContent([title, explanation, status, buttons], alignment: .leading, fullWidth: [explanation, status])
    }

    private func setContent(
        _ views: [NSView],
        alignment: NSLayoutConstraint.Attribute,
        fullWidth: [NSView]
    ) {
        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        NSLayoutConstraint.activate(fullWidth.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    func showSuccess() {
        didCompleteSetup = true
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))

        let title = NSTextField(labelWithString: "The driver is running")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "The driver is installed and running in the background. It starts automatically when you log in.\n\nIf a touchscreen needs pairing, the driver will show a target to touch."
        )
        explanation.alignment = .center
        let done = NSButton(title: "Done", target: self, action: #selector(finishSetup))
        done.keyEquivalent = "\r"
        window.setContentSize(NSSize(width: 470, height: 245))
        setContent([mark, title, explanation, done], alignment: .centerX, fullWidth: [explanation])
        window.makeFirstResponder(done)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismiss() {
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if didCompleteSetup { onDone() }
        else { onQuit() }
        return false
    }

    @objc private func finishSetup() {
        onDone()
    }

    @objc private func quitSetup() {
        onQuit()
    }

    @objc private func checkAgain() {
        if checkAccess() {
            onGranted()
        } else {
            status.stringValue =
                "macOS still reports access is missing. In Privacy & Security, check that the permission entry matches the installed MacXeneonEdgeTouchDriver, then click Check Again."
        }
    }

    @objc private func openSettings() {
        if !didRequestAccess {
            didRequestAccess = true
            DispatchQueue.global(qos: .userInitiated).async(execute: requestAccess)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences"),
              NSWorkspace.shared.open(url) else {
            status.stringValue = "Open System Settings manually, then go to Privacy & Security to allow the driver."
            return
        }
    }
}
