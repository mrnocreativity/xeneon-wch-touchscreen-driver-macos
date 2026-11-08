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

/// Guides the user through missing mouse-event access and confirms startup.
final class MousePermissionSetupWindow: NSObject, NSWindowDelegate {
    private let onGranted: () -> Void
    private let onQuit: () -> Void
    private let onDone: () -> Void
    private var requestedPermissions: Set<DriverPrivacyPermission> = []
    private(set) var didCompleteSetup = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 470, height: 245),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    init(
        onGranted: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.onGranted = onGranted
        self.onQuit = onQuit
        self.onDone = onDone
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
