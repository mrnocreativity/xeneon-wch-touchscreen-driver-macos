import AppKit
import ApplicationServices

enum DriverPrivacyPermission: CaseIterable {
    case mouseEvents
    case inputMonitoring

    var isGranted: Bool {
        switch self {
        case .mouseEvents: CGPreflightPostEventAccess() || AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    var settingName: String {
        switch self {
        case .mouseEvents: "Device Control and Data Access (Accessibility on earlier macOS)"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    func request() {
        switch self {
        case .mouseEvents:
            guard !CGRequestPostEventAccess() else { return }
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    static var missing: [Self] { allCases.filter { !$0.isGranted } }
}

/// Guides the user through granting the driver's privacy permissions.
final class MousePermissionSetupWindow: NSObject, NSWindowDelegate {
    private let onGranted: () -> Void
    private let onQuit: () -> Void
    private var requestedPermissions: Set<DriverPrivacyPermission> = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 470, height: 245),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    init(
        onGranted: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onGranted = onGranted
        self.onQuit = onQuit
        super.init()

        window.title = "Xeneon Touchscreen Driver Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "Setup incomplete · Privacy access required")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .systemRed
        let explanation = NSTextField(wrappingLabelWithString:
            "The driver is installed. It needs privacy access to read touches and turn them into mouse events."
        )
        showMissing(DriverPrivacyPermission.missing)
        status.textColor = .systemRed

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitSetup))
        quit.keyEquivalent = "\u{1b}"
        let check = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        let settings = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openSettings))
        settings.keyEquivalent = "\r"
        window.defaultButtonCell = settings.cell as? NSButtonCell
        window.initialFirstResponder = settings
        let buttons = NSStackView(views: [quit, check, settings])
        buttons.spacing = 8

        setContent([title, explanation, status], fullWidth: [explanation, status], buttons: buttons)
    }

    private func setContent(
        _ views: [NSView],
        fullWidth: [NSView],
        buttons: NSStackView
    ) {
        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        NSLayoutConstraint.activate(fullWidth.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
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
        let missing = DriverPrivacyPermission.missing
        if missing.isEmpty {
            onGranted()
        } else {
            showMissing(missing)
        }
    }

    private func showMissing(_ missing: [DriverPrivacyPermission]) {
        guard !missing.isEmpty else {
            status.stringValue = "Click Check Again to start the driver."
            return
        }
        let names = missing.map(\.settingName).joined(separator: " and ")
        status.stringValue = "Allow MacXeneonEdgeTouchDriver under \(names) in Privacy & Security, then click Check Again."
    }

    @objc private func openSettings() {
        let missing = DriverPrivacyPermission.missing
        guard !missing.isEmpty else { onGranted(); return }
        showMissing(missing)
        if let permission = missing.first(where: { !requestedPermissions.contains($0) }) {
            requestedPermissions.insert(permission)
            DispatchQueue.global(qos: .userInitiated).async { permission.request() }
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security"),
              NSWorkspace.shared.open(url) else {
            status.stringValue = "Open System Settings manually, then go to Privacy & Security to allow the driver."
            return
        }
    }
}
