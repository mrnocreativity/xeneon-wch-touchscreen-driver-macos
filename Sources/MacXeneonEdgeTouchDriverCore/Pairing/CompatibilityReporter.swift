import AppKit
import CoreGraphics
import Foundation

/// Offers a report after physical pairing succeeds on a display outside the catalog.
final class CompatibilityReporter: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var pending: [(key: String, name: String, body: String)] = []
    private var waitingForInstaller = false
    private var window: NSPanel?
    private var currentReport: (name: String, body: String)?
    private var reportPreview: NSScrollView?
    private var openGitHubButton: NSButton?
    private var dismissButton: NSButton?
    private let collapsedHeight: CGFloat = 295
    private let previewHeight: CGFloat = 152

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func enqueue(_ display: DisplaySnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = Self.promptKey(for: display)
            guard !self.defaults.bool(forKey: key), !self.pending.contains(where: { $0.key == key }) else { return }
            let name = NSScreen.screens.first {
                let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
                return ($0.deviceDescription[screenNumber] as? NSNumber)?.uint32Value == display.displayID &&
                    CGDisplayVendorNumber(display.displayID) == display.vendorNumber &&
                    CGDisplayModelNumber(display.displayID) == display.modelNumber
            }?.localizedName ?? "Unlisted touchscreen"
            self.pending.append((key, name, Self.report(for: display, name: name)))
        }
    }

    func presentPending() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil, !self.pending.isEmpty else { return }
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.ajvwhite.MacXeneonEdgeTouchDriver.Installer"
            ).contains(where: { !$0.isTerminated }) {
                // Let the user finish the installer's confirmation before offering a report.
                guard !self.waitingForInstaller else { return }
                self.waitingForInstaller = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.waitingForInstaller = false
                    self?.presentPending()
                }
                return
            }
            let report = self.pending.removeFirst()
            if self.claimPrompt(key: report.key) {
                self.present(name: report.name, body: report.body)
            } else {
                self.presentPending()
            }
        }
    }

    @discardableResult
    func claimPrompt(key: String) -> Bool {
        guard !defaults.bool(forKey: key) else { return false }
        // Showing the invitation uses this model's one prompt, including a dismissal.
        defaults.set(true, forKey: key)
        return true
    }

    static func promptKey(for display: DisplaySnapshot) -> String {
        "compatibility-report-offered.\(display.vendorNumber).\(display.modelNumber)"
    }

    static func report(for display: DisplaySnapshot, name: String) -> String {
        let usbID = String(format: "%04X:%04X", XeneonEdgeDevice.vendorID, XeneonEdgeDevice.productID)
        return """
        ## Touchscreen compatibility report

        - Display name reported by macOS: \(name)
        - Display vendor ID: \(display.vendorNumber)
        - Display model ID: \(display.modelNumber)
        - Display mode during pairing: \(display.pixelsWide) × \(display.pixelsHigh)
        - USB touch interface: WCH \(usbID), Generic Desktop / Mouse
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Pairing: confirmed by touching and releasing the on-screen target

        If known, add the exact retail brand and model, a product link, native resolution, and how the display is connected.
        """
    }

    private func present(name: String, body: String) {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: collapsedHeight),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Touchscreen Paired"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let heading = NSTextField(labelWithString: "Help us identify this touchscreen")
        heading.font = .boldSystemFont(ofSize: 17)
        let detail = NSTextField(wrappingLabelWithString:
            "Your touchscreen paired successfully. Share a compatibility report to help other owners find it.")
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 440, height: 152))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = body
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.isHidden = true

        let dismiss = NSButton(title: "No Thanks", target: self, action: #selector(dismissReport))
        dismiss.keyEquivalent = "\u{1b}"
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        let open = NSButton(title: "Open GitHub", target: self, action: #selector(openGitHub))
        let previewLink = NSButton(title: "Show report", target: self, action: #selector(togglePreview(_:)))
        previewLink.isBordered = false
        stylePreviewLink(previewLink, title: "Show report")
        let copyStep = reportStep("1. Copy the compatibility report.", button: copy)
        let openStep = reportStep("2. Open a new GitHub issue.", button: open)
        let pasteStep = NSTextField(wrappingLabelWithString: "3. Paste the report into the issue description.")
        let submitStep = NSTextField(wrappingLabelWithString:
            "4. If you have a link to your exact touchscreen model, add it (for example, its Amazon listing). Then click Submit new issue.")
        let stack = NSStackView(views: [heading, detail, copyStep, previewLink, scroll, openStep, pasteStep, submitStep])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            content.addSubview(dismiss)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: dismiss.topAnchor, constant: -12),
                detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
                copyStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
                openStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
                submitStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: previewHeight),
                dismiss.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                dismiss.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
            ])
        }

        currentReport = (name, body)
        reportPreview = scroll
        openGitHubButton = open
        dismissButton = dismiss
        window = panel
        setDefaultButton(copy)
        panel.initialFirstResponder = copy
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func dismissReport() {
        window?.close()
    }

    private func reportStep(_ text: String, button: NSButton) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        button.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, button])
        row.spacing = 12
        return row
    }

    private func stylePreviewLink(_ button: NSButton, title: String) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
    }

    @objc private func togglePreview(_ sender: NSButton) {
        guard let reportPreview, let window else { return }
        reportPreview.isHidden.toggle()
        stylePreviewLink(sender, title: reportPreview.isHidden ? "Show report" : "Hide report")
        let height = reportPreview.isHidden ? collapsedHeight : collapsedHeight + previewHeight + 8
        var frame = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 480, height: height))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }

    private func setDefaultButton(_ button: NSButton) {
        if window?.defaultButtonCell?.keyEquivalent == "\r" {
            window?.defaultButtonCell?.keyEquivalent = ""
        }
        button.keyEquivalent = "\r"
        window?.defaultButtonCell = button.cell as? NSButtonCell
    }

    @objc private func copyReport(_ sender: NSButton) {
        guard let currentReport else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(currentReport.body, forType: .string) else { return }
        sender.title = "Copied ✓"
        dismissButton?.title = "Close"
        if let openGitHubButton {
            setDefaultButton(openGitHubButton)
            window?.makeFirstResponder(openGitHubButton)
        }
    }

    @objc private func openGitHub() {
        guard let currentReport else { return }
        var issue = URLComponents()
        issue.scheme = "https"
        issue.host = "github.com"
        issue.path = "/mrnocreativity/xeneon-wch-touchscreen-driver-macos/issues/new"
        issue.queryItems = [
            URLQueryItem(name: "blank", value: "1"),
            URLQueryItem(name: "title", value: "[Compatibility]: \(currentReport.name)")
        ]
        if let url = issue.url, NSWorkspace.shared.open(url), let dismissButton {
            dismissButton.title = "Done"
            setDefaultButton(dismissButton)
            window?.makeFirstResponder(dismissButton)
        }
    }

    func windowWillClose(_ notification: Notification) {
        currentReport = nil
        reportPreview = nil
        openGitHubButton = nil
        dismissButton = nil
        window = nil
        presentPending()
    }
}
