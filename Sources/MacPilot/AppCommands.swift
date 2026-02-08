import ArgumentParser
import AppKit
import ApplicationServices
import Foundation

private func appHasAXWindows(_ pid: pid_t) -> Bool {
    let appElement = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return false
    }
    return !windows.isEmpty
}

private func runAppleScript(_ source: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func sendCommandN() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
    let nDown = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: true)
    let nUp = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: false)
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)

    nDown?.flags = .maskCommand
    nUp?.flags = .maskCommand

    let eventTap = CGEventTapLocation.cghidEventTap
    cmdDown?.post(tap: eventTap)
    nDown?.post(tap: eventTap)
    nUp?.post(tap: eventTap)
    cmdUp?.post(tap: eventTap)
}

private func appHasVisibleWindowOnCurrentSpace(_ pid: pid_t) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
    return windows.contains { win in
        let layer = win[kCGWindowLayer as String] as? Int ?? -1
        let ownerPID = win[kCGWindowOwnerPID as String] as? Int ?? 0
        return layer == 0 && ownerPID == Int(pid)
    }
}

private func bringAppFrontmost(_ appName: String, app: NSRunningApplication) {
    _ = NSApplication.shared
    NSApp?.activate(ignoringOtherApps: true)
    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    let escapedName = appName.replacingOccurrences(of: "\"", with: "\\\"")
    _ = runAppleScript("tell application \"\(escapedName)\" to activate")
    _ = runAppleScript("tell application \"System Events\" to set frontmost of process \"\(escapedName)\" to true")
}

private func ensureWindowExists(for app: NSRunningApplication, appName: String) {
    bringAppFrontmost(appName, app: app)

    let escapedName = appName.replacingOccurrences(of: "\"", with: "\\\"")
    if !appHasAXWindows(app.processIdentifier) || !appHasVisibleWindowOnCurrentSpace(app.processIdentifier) {
        _ = runAppleScript("tell application \"\(escapedName)\" to make new document")
        usleep(150_000)
        if !appHasVisibleWindowOnCurrentSpace(app.processIdentifier) {
            sendCommandN()
        }
    }

    let deadline = Date().addingTimeInterval(3)
    var attemptedExtraNewWindow = false
    while Date() < deadline {
        let hasWindow = appHasAXWindows(app.processIdentifier)
        let isVisible = appHasVisibleWindowOnCurrentSpace(app.processIdentifier)
        if hasWindow && isVisible { return }
        if !isVisible && !attemptedExtraNewWindow {
            sendCommandN()
            attemptedExtraNewWindow = true
        }
        bringAppFrontmost(appName, app: app)
        usleep(120_000)
    }
}

private func openApp(named name: String, json: Bool) throws {
    let config = NSWorkspace.OpenConfiguration()
    let semaphore = DispatchSemaphore(value: 0)
    var openError: Error?
    let launchTimeout: TimeInterval = 5

    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let looksLikeBundleID = trimmed.contains(".") && !trimmed.contains("/") && !trimmed.contains(" ")

    var attempts: [String] = []
    var appURL: URL?

    if looksLikeBundleID {
        attempts.append("bundle-id lookup")
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
    }

    if appURL == nil {
        attempts.append("name lookup")
        appURL = findAppURL(trimmed)
    }

    guard let url = appURL else {
        JSONOutput.error(
            "App not found: \(name). Tried: \(attempts.joined(separator: ", "))",
            json: json
        )
        throw ExitCode.failure
    }

    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        openError = error
        semaphore.signal()
    }

    let launchDeadline = Date().addingTimeInterval(launchTimeout)
    var completedLaunchCallback = false
    while Date() < launchDeadline {
        if semaphore.wait(timeout: .now()) == .success {
            completedLaunchCallback = true
            break
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    guard completedLaunchCallback else {
        JSONOutput.error("Timed out opening \(name) after \(Int(launchTimeout)) seconds", json: json)
        throw ExitCode.failure
    }

    if let error = openError {
        JSONOutput.error("Failed to open \(name): \(error.localizedDescription)", json: json)
        throw ExitCode.failure
    }

    let bundleID = Bundle(url: url)?.bundleIdentifier
    let findRunningApp = {
        bundleID
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(trimmed) == true
            })
    }

    var runningApp = findRunningApp()
    let runningAppDeadline = Date().addingTimeInterval(launchTimeout)
    while runningApp == nil, Date() < runningAppDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        runningApp = findRunningApp()
    }

    guard let runningApp else {
        JSONOutput.error("Timed out waiting for \(name) to launch after \(Int(launchTimeout)) seconds", json: json)
        throw ExitCode.failure
    }

    ensureWindowExists(for: runningApp, appName: runningApp.localizedName ?? trimmed)

    flashIndicatorIfRunning()

    JSONOutput.print([
        "status": "ok",
        "message": "Opened \(name)",
        "appPath": url.path,
    ], json: json)
}

private func focusApp(named name: String, json: Bool) throws {
    let apps = NSWorkspace.shared.runningApplications
    guard let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) else {
        JSONOutput.error("App not running: \(name)", json: json)
        throw ExitCode.failure
    }
    app.activate()
    flashIndicatorIfRunning()
    JSONOutput.print(["status": "ok", "message": "Focused \(app.localizedName ?? name)"], json: json)
}

struct App: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "App management",
        subcommands: [AppOpen.self, AppLaunch.self, AppFocus.self, AppActivate.self, AppFrontmost.self, AppList.self, AppQuit.self]
    )
}

struct AppOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open an application")

    @Argument(help: "App name or bundle identifier") var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        try openApp(named: name, json: json)
    }
}

struct AppLaunch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Launch an application (alias for open)")

    @Argument(help: "App name or bundle identifier") var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        try openApp(named: name, json: json)
    }
}

struct AppFocus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus", abstract: "Focus/activate an app")

    @Argument var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        try focusApp(named: name, json: json)
    }
}

struct AppActivate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "activate", abstract: "Activate an app (alias for focus)")

    @Argument(help: "App name") var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        try focusApp(named: name, json: json)
    }
}

struct AppFrontmost: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "frontmost", abstract: "Show the frontmost app")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else {
            JSONOutput.error("No frontmost app", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Frontmost app: \(name)",
            "name": name,
            "pid": app.processIdentifier,
            "bundleId": app.bundleIdentifier ?? "",
        ], json: json)
    }
}

struct AppList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List running apps")

    @Flag(name: .long) var json = false

    func run() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let name = app.localizedName else { return nil }
                return [
                    "name": name,
                    "pid": app.processIdentifier,
                    "bundleId": app.bundleIdentifier ?? "",
                    "active": app.isActive,
                ]
            }

        if json {
            JSONOutput.printArray(apps, json: true)
        } else {
            for app in apps {
                let name = app["name"] as? String ?? ""
                let pid = app["pid"] as? pid_t ?? 0
                let active = (app["active"] as? Bool == true) ? " *" : ""
                print("\(name) (pid: \(pid))\(active)")
            }
        }
    }
}

struct AppQuit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit an app")

    @Argument var name: String
    @Flag(name: .long, help: "Force quit") var force = false
    @Flag(name: .long) var json = false

    func run() throws {
        if let reason = Safety.validateQuit(appName: name) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) else {
            JSONOutput.error("App not running: \(name)", json: json)
            throw ExitCode.failure
        }

        if let resolvedName = app.localizedName, let reason = Safety.validateQuit(appName: resolvedName) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": "Quit \(app.localizedName ?? name)"], json: json)
    }
}

func findAppURL(_ name: String) -> URL? {
    if name.hasSuffix(".app"), FileManager.default.fileExists(atPath: name) {
        return URL(fileURLWithPath: name)
    }

    if let appByName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
        return appByName
    }

    if let appByNamePath = NSWorkspace.shared.fullPath(forApplication: name) {
        return URL(fileURLWithPath: appByNamePath)
    }

    let cleanName = name.replacingOccurrences(of: ".app", with: "")
    let paths = ["/Applications", "/System/Applications", "/Applications/Utilities"]
    for path in paths {
        let appPath = "\(path)/\(cleanName).app"
        if FileManager.default.fileExists(atPath: appPath) {
            return URL(fileURLWithPath: appPath)
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(cleanName)'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8),
       let firstLine = output.split(separator: "\n").first {
        let result = String(firstLine)
        if !result.isEmpty {
            return URL(fileURLWithPath: result)
        }
    }

    return nil
}
