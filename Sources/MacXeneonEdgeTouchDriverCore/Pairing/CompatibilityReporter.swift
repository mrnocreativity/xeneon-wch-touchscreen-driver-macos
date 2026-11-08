import AppKit
import CoreGraphics
import Foundation

/// Offers a report after physical pairing succeeds on a display outside the catalog.
final class CompatibilityReporter: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var pending: [(key: String, name: String, body: String)] = []
    private var window: NSPanel?
    private var currentReport: (name: String, body: String)?

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
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Touchscreen Paired"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let heading = NSTextField(labelWithString: "Help us identify this touchscreen")
        heading.font = .boldSystemFont(ofSize: 17)
        let detail = NSTextField(wrappingLabelWithString:
            "Your touchscreen paired successfully. You can help others find it by pasting this report into a new GitHub issue.")
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

        let dismiss = NSButton(title: "No Thanks", target: self, action: #selector(dismissReport))
        dismiss.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: "Copy Report and Open GitHub", target: self, action: #selector(copyReport))
        copy.keyEquivalent = "\r"
        let buttons = NSStackView(views: [dismiss, copy])
        buttons.spacing = 10
        let stack = NSStackView(views: [heading, detail, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
                detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: 152)
            ])
        }

        currentReport = (name, body)
        window = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func dismissReport() {
        window?.close()
    }

    @objc private func copyReport() {
        guard let currentReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentReport.body, forType: .string)
        var issue = URLComponents()
        issue.scheme = "https"
        issue.host = "github.com"
        issue.path = "/mrnocreativity/xeneon-wch-touchscreen-driver-macos/issues/new"
        issue.queryItems = [
            URLQueryItem(name: "blank", value: "1"),
            URLQueryItem(name: "title", value: "[Compatibility]: \(currentReport.name)")
        ]
        dismissReport()
        if let url = issue.url { NSWorkspace.shared.open(url) }
    }

    func windowWillClose(_ notification: Notification) {
        currentReport = nil
        window = nil
        presentPending()
    }
}
