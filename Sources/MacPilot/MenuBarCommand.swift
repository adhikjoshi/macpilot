import ArgumentParser
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

private var menuBarController: MenuBarController?

private enum MenuBarSettingsURL {
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let automation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

private final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let permissionHeaderItem = NSMenuItem(title: "Permission Status", action: nil, keyEquivalent: "")
    private let accessibilityStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let screenRecordingStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fullDiskStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let automationStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let grantAllItem = NSMenuItem(title: "Grant All Permissions", action: #selector(grantAllPermissions), keyEquivalent: "")
    private let accessibilitySettingsItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let screenRecordingSettingsItem = NSMenuItem(title: "Open Screen Recording Settings", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
    private let fullDiskSettingsItem = NSMenuItem(title: "Open Full Disk Access Settings", action: #selector(openFullDiskSettings), keyEquivalent: "")
    private let automationSettingsItem = NSMenuItem(title: "Open Automation Settings", action: #selector(openAutomationSettings), keyEquivalent: "")

    private let versionItem = NSMenuItem(title: "Version v0.5.0", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quitMenuBar), keyEquivalent: "q")

    override init() {
        super.init()
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItemButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionStatus()
    }

    private func buildMenu() {
        menu.delegate = self

        permissionHeaderItem.isEnabled = false
        accessibilityStatusItem.isEnabled = false
        screenRecordingStatusItem.isEnabled = false
        fullDiskStatusItem.isEnabled = false
        automationStatusItem.isEnabled = false
        versionItem.isEnabled = false

        grantAllItem.target = self
        accessibilitySettingsItem.target = self
        screenRecordingSettingsItem.target = self
        fullDiskSettingsItem.target = self
        automationSettingsItem.target = self
        quitItem.target = self

        menu.addItem(permissionHeaderItem)
        menu.addItem(accessibilityStatusItem)
        menu.addItem(screenRecordingStatusItem)
        menu.addItem(fullDiskStatusItem)
        menu.addItem(automationStatusItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(grantAllItem)
        menu.addItem(accessibilitySettingsItem)
        menu.addItem(screenRecordingSettingsItem)
        menu.addItem(fullDiskSettingsItem)
        menu.addItem(automationSettingsItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(versionItem)
        menu.addItem(quitItem)

        refreshPermissionStatus()
    }

    private func configureStatusItemButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "command.circle.fill", accessibilityDescription: "MacPilot") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "MP"
        }

        button.toolTip = "MacPilot"
        button.target = self
        button.action = #selector(showMenu(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func showMenu(_ sender: Any?) {
        refreshPermissionStatus()
        statusItem.popUpMenu(menu)
    }

    @objc private func grantAllPermissions() {
        openSettingsPane(MenuBarSettingsURL.accessibility)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.openSettingsPane(MenuBarSettingsURL.screenRecording)
            self?.postGrantNotification()
        }
    }

    @objc private func openAccessibilitySettings() {
        openSettingsPane(MenuBarSettingsURL.accessibility)
    }

    @objc private func openScreenRecordingSettings() {
        openSettingsPane(MenuBarSettingsURL.screenRecording)
    }

    @objc private func openFullDiskSettings() {
        openSettingsPane(MenuBarSettingsURL.fullDiskAccess)
    }

    @objc private func openAutomationSettings() {
        openSettingsPane(MenuBarSettingsURL.automation)
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }

    private func refreshPermissionStatus() {
        accessibilityStatusItem.title = "Accessibility: \(permissionMarker(checkAccessibilityPermission()))"
        screenRecordingStatusItem.title = "Screen Recording: \(permissionMarker(checkScreenRecordingPermission()))"
        fullDiskStatusItem.title = "Full Disk Access: \(permissionMarker(checkFullDiskAccessPermission()))"
        automationStatusItem.title = "Automation: \(permissionMarker(checkAutomationPermission()))"
    }

    private func permissionMarker(_ granted: Bool) -> String {
        granted ? "✅" : "❌"
    }

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    private func checkFullDiskAccessPermission() -> Bool {
        let fileManager = FileManager.default
        let mailPath = NSString(string: "~/Library/Mail").expandingTildeInPath
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"

        if canReadDirectory(mailPath, fileManager: fileManager) {
            return true
        }
        if canReadFile(tccPath) {
            return true
        }
        return false
    }

    private func canReadDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(atPath: path)) != nil
    }

    private func canReadFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (try? Data(contentsOf: url, options: .mappedIfSafe)) != nil
    }

    private func checkAutomationPermission() -> Bool {
        let source = "tell application \"System Events\" to count (every process)"
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    private func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if NSWorkspace.shared.open(url) {
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [urlString]
        try? task.run()
    }

    private func postGrantNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let notify = {
                let content = UNMutableNotificationContent()
                content.title = "MacPilot"
                content.body = "Toggle ON MacPilot in each settings pane"
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request, withCompletionHandler: nil)
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                notify()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        notify()
                    }
                }
            default:
                break
            }
        }
    }
}

struct MenuBar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menubar",
        abstract: "Launch the MacPilot menu bar item"
    )

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = MenuBarController()
        menuBarController = controller
        app.delegate = controller
        app.run()
    }
}
