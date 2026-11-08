import AppKit
import Foundation
import Darwin

// The signed app contains the installer scripts; installation runs as the
// current user and never requests administrator privileges.
let application = NSApplication.shared
application.setActivationPolicy(.regular)
final class InstallerDelegate: NSObject, NSApplicationDelegate {
    var operationInProgress = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            runInstallerFlow()
            if !self.operationInProgress { NSApplication.shared.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        operationInProgress ? .terminateCancel : .terminateNow
    }
    @objc func dismissCompletion() { NSApp.stopModal() }
}
let installerDelegate = InstallerDelegate()
application.delegate = installerDelegate

func showMessage(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    application.activate(ignoringOtherApps: true)
    alert.runModal()
}

func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    // Use a private log file, so a full pipe cannot deadlock an installation.
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { try? FileManager.default.removeItem(at: log) }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    task.standardOutput = output
    task.standardError = output
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["HOME"] = NSHomeDirectory()
    environment.removeValue(forKey: "CODESIGN_IDENTITY")
    environment.removeValue(forKey: "NOTARIZATION_PROFILE")
    task.environment = environment
    try task.run()
    task.waitUntilExit()
    let input = try FileHandle(forReadingFrom: log)
    defer { try? input.close() }
    let size = try input.seekToEnd()
    if size > 32_768 { try input.seek(toOffset: size - 32_768) }
    else { try input.seek(toOffset: 0) }
    return (task.terminationStatus, String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self))
}

func runInstallerFlow() {
    guard getuid() != 0, getuid() == geteuid() else {
        showMessage("Open this app as yourself", "Install the driver from your normal Mac account. Do not run this installer with sudo or as root.", style: .warning)
        return
    }
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app", let resources = Bundle.main.resourceURL else {
        showMessage("Installer files are missing", "Extract the complete portable installer ZIP and open Install Xeneon Touch.app.", style: .critical)
        return
    }
    do {
        // Verify the outer seal before executing any bundled shell resources.
        let check = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"com.ajvwhite.MacXeneonEdgeTouchDriver.Installer\"", bundle.path])
        guard check.0 == 0 else {
            showMessage("The installer could not be verified", "Its files may be incomplete or changed. Make a new portable installer on the development Mac.\n\n" + check.1, style: .critical)
            return
        }
        let outer = try run("/usr/bin/codesign", ["-dv", "--verbose=2", bundle.path])
        let driver = try run("/usr/bin/codesign", ["-dv", "--verbose=2", bundle.appendingPathComponent("Contents/Helpers/MacXeneonEdgeTouchDriver").path])
        func team(_ text: String) -> String? {
            text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }).map(String.init)
        }
        guard outer.0 == 0, driver.0 == 0, let outerTeam = team(outer.1),
              outerTeam != "TeamIdentifier=not set", outerTeam == team(driver.1) else {
            showMessage("The installer and driver have different signers", "Make a new portable installer on the development Mac. No files were installed.", style: .critical)
            return
        }
    } catch {
        showMessage("The installer could not be verified", error.localizedDescription, style: .critical)
        return
    }

    let choice = NSAlert()
    choice.messageText = "Xeneon Edge touch driver"
    choice.informativeText = "Install or update the driver for your Mac account. Your settings and saved display pairings will be kept.\n\nLift every finger off the touchscreen and release all mouse buttons before continuing."
    choice.addButton(withTitle: "Install or Update")
    choice.addButton(withTitle: "Remove Driver")
    choice.addButton(withTitle: "Cancel")
    application.activate(ignoringOtherApps: true)
    let response = choice.runModal()
    let removing = response == .alertSecondButtonReturn
    guard response == .alertFirstButtonReturn || removing else { return }
    if removing {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Remove the driver and its settings?"
        confirm.informativeText = "This removes the driver, your settings, saved display pairings and installation backups from this Mac account. Logs are kept. Keep fingers off the touchscreen and release mouse buttons."
        confirm.addButton(withTitle: "Cancel")
        confirm.addButton(withTitle: "Remove Driver")
        guard confirm.runModal() == .alertSecondButtonReturn else { return }
    } else {
        let driver = bundle.appendingPathComponent("Contents/Helpers/MacXeneonEdgeTouchDriver")
        let probeStatus = (try? run(driver.path, ["--check-hardware"]))?.0
        if probeStatus != 0 {
            let warning = NSAlert()
            warning.alertStyle = .warning
            switch probeStatus {
            case 3:
                warning.messageText = "No supported touch controller detected"
                warning.informativeText = "The driver will only provide touch input once a supported touchscreen is connected over USB. Check your USB data connection, or install now and connect a supported touchscreen later."
            case 4:
                warning.messageText = "Touch controller format could not be verified"
                warning.informativeText = "A USB touch controller was detected, but its touch reports may be incompatible with this driver."
            default:
                warning.messageText = "The hardware check could not run"
                warning.informativeText = "The installer could not determine whether this setup has a supported touch controller."
            }
            warning.addButton(withTitle: "Cancel")
            warning.addButton(withTitle: "Install Anyway")
            warning.buttons[0].keyEquivalent = "\u{1b}"
            guard warning.runModal() == .alertSecondButtonReturn else { return }
        }
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = removing ? "Removing driver" : "Installing driver"
    window.isReleasedWhenClosed = false
    let label = NSTextField(labelWithString: "Please wait. Keep fingers off the touchscreen.")
    label.frame = NSRect(x: 24, y: 65, width: 355, height: 20)
    let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 28, width: 352, height: 20))
    progress.style = .bar
    progress.isIndeterminate = true
    window.contentView?.addSubview(label)
    window.contentView?.addSubview(progress)
    window.center()
    window.makeKeyAndOrderFront(nil)
    progress.startAnimation(nil)
    let script = resources.appendingPathComponent(removing ? "Scripts/uninstall.sh" : "Scripts/install.sh")
    let arguments = [script.path] + (removing ? [] : ["--prebuilt"])
    installerDelegate.operationInProgress = true
    DispatchQueue.global(qos: .userInitiated).async {
        let result: (Int32, String)
        do { result = try run("/bin/sh", arguments) }
        catch { result = (1, error.localizedDescription) }
        DispatchQueue.main.async {
            window.close()
            if result.0 != 0 {
                showMessage(removing ? "Removal did not finish" : "Installation did not finish",
                            "The details below explain what happened. If recovery was incomplete, keep the saved backups.\n\n" + result.1,
                            style: .critical)
            } else if removing {
                showMessage("Driver removed", "The driver and its settings have been removed from this Mac account. Logs were kept.")
            } else {
                installerDelegate.operationInProgress = false
                DispatchQueue.global(qos: .userInitiated).async {
                    let setup = waitForDriverSetup()
                    DispatchQueue.main.async {
                        showInstalled(setup)
                        application.terminate(nil)
                    }
                }
                return
            }
            installerDelegate.operationInProgress = false
            application.terminate(nil)
        }
    }
}

enum DriverSetup: String {
    case ready
    case privacyRequired
    case discovering
    case waitingForHardware
    case pairing
    case cancelled
}

func waitForDriverSetup() -> DriverSetup? {
    let driver = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/MacXeneonEdgeTouchDriver/bin/MacXeneonEdgeTouchDriver")
    var lastState: DriverSetup?
    var stateSince = ProcessInfo.processInfo.systemUptime
    while true {
        let state: DriverSetup?
        if let (exitCode, reply) = try? run(driver.path, ["setup-status"]), exitCode == 0,
           let response = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String] {
            state = response["state"].flatMap(DriverSetup.init(rawValue:))
        } else {
            state = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if state != lastState {
            lastState = state
            stateSince = now
        }
        switch state {
        case .ready, .cancelled: return state
        case .waitingForHardware, .discovering, nil:
            if now - stateSince >= 5 { return state }
        case .privacyRequired, .pairing:
            // The driver owns these steps. Keep the installer out of the way.
            break
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

func showInstalled(_ setup: DriverSetup?) {
    switch setup {
    case .ready:
        showCompletion()
    case .waitingForHardware:
        showMessage("Connect a supported touchscreen",
                    "The driver is installed. Connect your touchscreen over USB to continue setup.")
    case .cancelled:
        showMessage("Touchscreen setup was cancelled",
                    "The driver is installed. Run Install or Update again when you’re ready to finish pairing.")
    case .privacyRequired, .pairing:
        break
    case .discovering, nil:
        showMessage("Driver startup could not be confirmed",
                    "The driver files were installed, but the driver did not report that it started. Try Install or Update again.",
                    style: .warning)
    }
}

func showCompletion() {
    let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 222),
                         styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Touchscreen Setup"
    let checkmark = NSImageView()
    checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
    checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 54, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
    let title = NSTextField(labelWithString: "Your touchscreen driver is ready")
    title.font = .boldSystemFont(ofSize: 17)
    let message = NSTextField(wrappingLabelWithString:
        "The driver is running in the background and starts automatically when you log in.")
    message.alignment = .center
    let done = NSButton(title: "Done", target: installerDelegate, action: #selector(InstallerDelegate.dismissCompletion))
    done.keyEquivalent = "\r"
    let stack = NSStackView(views: [checkmark, title, message, done])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    guard let content = window.contentView else { return }
    content.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        message.widthAnchor.constraint(equalToConstant: 320)
    ])
    window.center()
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    application.runModal(for: window)
    window.orderOut(nil)
}

let menu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
let quit = NSMenuItem(title: "Quit Install Xeneon Touch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
quit.target = application
appMenu.addItem(quit)
appMenuItem.submenu = appMenu
menu.addItem(appMenuItem)
application.mainMenu = menu
application.run()
