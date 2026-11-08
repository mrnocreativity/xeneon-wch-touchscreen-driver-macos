import AppKit

/// Shown only while the driver cannot post the mouse events it generates from touch.
final class MousePermissionSetupWindow: NSObject, NSWindowDelegate {
    private let checkAccess: () -> Bool
    private let requestAccess: @Sendable () -> Void
    private let onGranted: () -> Void
    private let onQuit: () -> Void
    private var didRequestAccess = false
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
        onQuit: @escaping () -> Void
    ) {
        self.checkAccess = checkAccess
        self.requestAccess = requestAccess
        self.onGranted = onGranted
        self.onQuit = onQuit
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

        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: [title, explanation, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
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
        onQuit()
        return false
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
