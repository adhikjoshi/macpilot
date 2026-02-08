import ArgumentParser
import AppKit
import Foundation

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window management",
        subcommands: [WindowList.self, WindowFocus.self, WindowNew.self, WindowResize.self, WindowMove.self, WindowClose.self, WindowMinimize.self, WindowFullscreen.self]
    )
}

// MARK: - Helpers

private func getAppWindows(_ appName: String?) -> (pid_t, AXUIElement, [AXUIElement])? {
    guard let pid = findAppPID(appName) else { return nil }
    let appElement = AXUIElementCreateApplication(pid)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], !windows.isEmpty else {
        return nil
    }
    return (pid, appElement, windows)
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

private func isWindowVisibleOnCurrentSpace(_ win: AXUIElement, pid: pid_t?) -> Bool {
    guard let pid else { return false }

    let axTitle = getAttr(win, kAXTitleAttribute) ?? ""
    let axPos = getPosition(win)
    let axSize = getSize(win)

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }

    let pidWindows = windows.filter {
        let layer = $0[kCGWindowLayer as String] as? Int ?? -1
        let ownerPID = $0[kCGWindowOwnerPID as String] as? Int ?? 0
        return layer == 0 && ownerPID == Int(pid)
    }

    guard !pidWindows.isEmpty else { return false }

    guard let axPos, let axSize else { return true }

    for cgWin in pidWindows {
        let cgTitle = cgWin[kCGWindowName as String] as? String ?? ""
        if !axTitle.isEmpty, !cgTitle.isEmpty,
           !cgTitle.localizedCaseInsensitiveContains(axTitle),
           !axTitle.localizedCaseInsensitiveContains(cgTitle) {
            continue
        }

        guard let bounds = cgWin[kCGWindowBounds as String] as? [String: Any] else { continue }
        let x = bounds["X"] as? Double ?? Double(bounds["X"] as? Int ?? 0)
        let y = bounds["Y"] as? Double ?? Double(bounds["Y"] as? Int ?? 0)
        let w = bounds["Width"] as? Double ?? Double(bounds["Width"] as? Int ?? 0)
        let h = bounds["Height"] as? Double ?? Double(bounds["Height"] as? Int ?? 0)

        let closeEnough = abs(axPos.x - x) < 40 && abs(axPos.y - y) < 40 && abs(axSize.width - w) < 60 && abs(axSize.height - h) < 60
        if closeEnough { return true }
    }

    return false
}

private func windowInfo(_ win: AXUIElement, pid: pid_t? = nil) -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["title"] = getAttr(win, kAXTitleAttribute) ?? ""
    dict["role"] = getAttr(win, kAXRoleAttribute) ?? ""
    dict["subrole"] = getAttr(win, kAXSubroleAttribute) ?? ""
    if let pos = getPosition(win) {
        dict["x"] = Int(pos.x)
        dict["y"] = Int(pos.y)
    }
    if let sz = getSize(win) {
        dict["width"] = Int(sz.width)
        dict["height"] = Int(sz.height)
    }
    dict["visible"] = isWindowVisibleOnCurrentSpace(win, pid: pid)
    // minimized?
    var minVal: AnyObject?
    if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success {
        dict["minimized"] = (minVal as? Bool) ?? false
    }
    return dict
}

private func setPosition(_ element: AXUIElement, x: Double, y: Double) {
    var point = CGPoint(x: x, y: y)
    if let value = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
}

private func setSize(_ element: AXUIElement, width: Double, height: Double) {
    var size = CGSize(width: width, height: height)
    if let value = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

// MARK: - Commands

struct WindowList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all windows with positions/sizes")

    @Option(name: .long, help: "App name") var app: String?
    @Flag(name: .long, help: "Include windows from all Spaces (via CG API)") var allSpaces = false
    @Flag(name: .long) var json = false

    func run() throws {
        var results: [[String: Any]] = []

        // Use AX API for per-app, CG API for all-spaces overview
        if allSpaces && app == nil {
            // Use CGWindowListCopyWindowInfo which can see all windows
            let option: CGWindowListOption = [.optionAll, .excludeDesktopElements]
            if let windowList = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] {
                for win in windowList {
                    let layer = win[kCGWindowLayer as String] as? Int ?? -1
                    guard layer == 0 else { continue } // normal windows only
                    let ownerName = win[kCGWindowOwnerName as String] as? String ?? ""
                    let name = win[kCGWindowName as String] as? String ?? ""
                    let pid = win[kCGWindowOwnerPID as String] as? Int ?? 0
                    let windowID = win[kCGWindowNumber as String] as? Int ?? 0
                    var info: [String: Any] = [
                        "app": ownerName,
                        "title": name,
                        "pid": pid,
                        "windowID": windowID,
                        "visible": (win[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                    ]
                    if let bounds = win[kCGWindowBounds as String] as? [String: Any] {
                        info["x"] = bounds["X"] as? Int ?? 0
                        info["y"] = bounds["Y"] as? Int ?? 0
                        info["width"] = bounds["Width"] as? Int ?? 0
                        info["height"] = bounds["Height"] as? Int ?? 0
                    }
                    results.append(info)
                }
            }
        } else if let appName = app {
            guard let (pid, _, windows) = getAppWindows(appName) else {
                JSONOutput.error("No windows found for \(appName)", json: json)
                throw ExitCode.failure
            }
            for win in windows {
                var info = windowInfo(win, pid: pid)
                info["app"] = appName
                results.append(info)
            }
        } else {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            for runApp in apps {
                let pid = runApp.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                var value: AnyObject?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { continue }
                for win in windows {
                    var info = windowInfo(win, pid: pid)
                    info["app"] = runApp.localizedName ?? ""
                    info["pid"] = Int(pid)
                    results.append(info)
                }
            }
        }

        if json {
            JSONOutput.printArray(results, json: true)
        } else {
            for w in results {
                let app = w["app"] as? String ?? ""
                let title = w["title"] as? String ?? ""
                let x = w["x"] as? Int ?? 0
                let y = w["y"] as? Int ?? 0
                let width = w["width"] as? Int ?? 0
                let height = w["height"] as? Int ?? 0
                let visible = (w["visible"] as? Bool == true) ? "visible" : "hidden"
                print("\(app): \"\(title)\" (\(x),\(y) \(width)x\(height)) [\(visible)]")
            }
        }
    }
}

struct WindowFocus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus", abstract: "Focus and raise a window")

    @Argument(help: "App name (positional)") var appName: String?
    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long, help: "Optional window title substring") var title: String?
    @Flag(name: .long) var json = false

    func run() throws {
        let resolvedApp = app ?? appName
        guard let resolvedApp else {
            JSONOutput.error("Provide app name as positional arg or --app", json: json)
            throw ExitCode.failure
        }

        let runningApps = NSWorkspace.shared.runningApplications
        guard let runningApp = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(resolvedApp) == true }) else {
            JSONOutput.error("App not running: \(resolvedApp)", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        guard let (_, _, windows) = getAppWindows(resolvedApp) else {
            JSONOutput.error("No windows found for \(resolvedApp)", json: json)
            throw ExitCode.failure
        }

        let selectedWindow: AXUIElement? = {
            guard let titleFilter = title, !titleFilter.isEmpty else { return windows.first }
            return windows.first { win in
                let windowTitle = (getAttr(win, kAXTitleAttribute) ?? "")
                return windowTitle.localizedCaseInsensitiveContains(titleFilter)
            }
        }()

        guard let window = selectedWindow else {
            JSONOutput.error("No matching window found for app '\(resolvedApp)' title '\(title ?? "")'", json: json)
            throw ExitCode.failure
        }

        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raiseResult != .success {
            JSONOutput.error("Failed to raise window (AX error: \(raiseResult.rawValue))", json: json)
            throw ExitCode.failure
        }

        _ = NSApplication.shared
        NSApp?.activate(ignoringOtherApps: true)
        runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let processName = (runningApp.localizedName ?? resolvedApp).replacingOccurrences(of: "\"", with: "\\\"")
        _ = runAppleScript("tell application \"\(processName)\" to activate")
        _ = runAppleScript("tell application \"System Events\" to set frontmost of process \"\(processName)\" to true")

        let visibilityDeadline = Date().addingTimeInterval(3)
        var isVisible = isWindowVisibleOnCurrentSpace(window, pid: runningApp.processIdentifier)
        var attemptedNewWindow = false
        while !isVisible && Date() < visibilityDeadline {
            if !attemptedNewWindow {
                sendCommandN()
                attemptedNewWindow = true
            }
            usleep(120_000)
            isVisible = isWindowVisibleOnCurrentSpace(window, pid: runningApp.processIdentifier)
            if !isVisible,
               let (_, _, refreshedWindows) = getAppWindows(resolvedApp),
               let firstVisible = refreshedWindows.first(where: { isWindowVisibleOnCurrentSpace($0, pid: runningApp.processIdentifier) }) {
                _ = AXUIElementPerformAction(firstVisible, kAXRaiseAction as CFString)
                isVisible = isWindowVisibleOnCurrentSpace(firstVisible, pid: runningApp.processIdentifier)
            }
        }

        if !isVisible {
            JSONOutput.error("Window was raised but is not visible on the current Space", json: json)
            throw ExitCode.failure
        }

        let resolvedTitle = getAttr(window, kAXTitleAttribute) ?? ""
        JSONOutput.print([
            "status": "ok",
            "message": "Focused window '\(resolvedTitle)' in \(runningApp.localizedName ?? resolvedApp)",
            "app": runningApp.localizedName ?? resolvedApp,
            "title": resolvedTitle,
            "visible": isVisible,
        ], json: json)
    }
}

struct WindowNew: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Open a new window in an app")

    @Argument(help: "App name") var app: String
    @Flag(name: .long) var json = false

    func run() throws {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let runningApp = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(app) == true }) else {
            JSONOutput.error("App not running: \(app)", json: json)
            throw ExitCode.failure
        }

        let appName = runningApp.localizedName ?? app
        flashIndicatorIfRunning()
        runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let escapedName = appName.replacingOccurrences(of: "\"", with: "\\\"")
        _ = runAppleScript("tell application \"\(escapedName)\" to make new document")
        usleep(150_000)
        if getAppWindows(appName) == nil {
            sendCommandN()
        }

        let deadline = Date().addingTimeInterval(3)
        var selectedWindow: AXUIElement?
        while Date() < deadline {
            if let (_, _, windows) = getAppWindows(appName), let first = windows.first {
                selectedWindow = first
                break
            }
            usleep(100_000)
        }

        guard let selectedWindow else {
            JSONOutput.error("Failed to create new window in \(appName)", json: json)
            throw ExitCode.failure
        }

        var info = windowInfo(selectedWindow, pid: runningApp.processIdentifier)
        info["status"] = "ok"
        info["message"] = "Opened new window in \(appName)"
        info["app"] = appName
        JSONOutput.print(info, json: json)
    }
}

struct WindowResize: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resize", abstract: "Resize window")

    @Argument(help: "App name (positional)") var appName: String?
    @Argument(help: "Width (positional)") var positionalWidth: Double?
    @Argument(help: "Height (positional)") var positionalHeight: Double?
    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long) var width: Double?
    @Option(name: .long) var height: Double?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let resolvedApp = app ?? appName else {
            JSONOutput.error("Provide app name as positional arg or --app", json: json)
            throw ExitCode.failure
        }
        guard let resolvedWidth = width ?? positionalWidth,
              let resolvedHeight = height ?? positionalHeight else {
            JSONOutput.error("Provide width/height as positional args or --width/--height", json: json)
            throw ExitCode.failure
        }

        guard let (_, _, windows) = getAppWindows(resolvedApp), let win = windows.first else {
            JSONOutput.error("No windows found for \(resolvedApp)", json: json)
            throw ExitCode.failure
        }
        flashIndicatorIfRunning()
        setSize(win, width: resolvedWidth, height: resolvedHeight)
        JSONOutput.print(["status": "ok", "message": "Resized \(resolvedApp) to \(Int(resolvedWidth))x\(Int(resolvedHeight))"], json: json)
    }
}

struct WindowMove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move window")

    @Argument(help: "App name (positional)") var appName: String?
    @Argument(help: "X position (positional)") var positionalX: Double?
    @Argument(help: "Y position (positional)") var positionalY: Double?
    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long) var x: Double?
    @Option(name: .long) var y: Double?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let resolvedApp = app ?? appName else {
            JSONOutput.error("Provide app name as positional arg or --app", json: json)
            throw ExitCode.failure
        }
        guard let resolvedX = x ?? positionalX,
              let resolvedY = y ?? positionalY else {
            JSONOutput.error("Provide x/y as positional args or --x/--y", json: json)
            throw ExitCode.failure
        }

        guard let (_, _, windows) = getAppWindows(resolvedApp), let win = windows.first else {
            JSONOutput.error("No windows found for \(resolvedApp)", json: json)
            throw ExitCode.failure
        }
        flashIndicatorIfRunning()
        setPosition(win, x: resolvedX, y: resolvedY)
        JSONOutput.print(["status": "ok", "message": "Moved \(resolvedApp) to (\(Int(resolvedX)),\(Int(resolvedY)))"], json: json)
    }
}

struct WindowClose: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close frontmost window (not quit)")

    @Option(name: .long, help: "App name") var app: String
    @Flag(name: .long) var json = false

    func run() throws {
        guard let (_, _, windows) = getAppWindows(app), let win = windows.first else {
            JSONOutput.error("No windows found for \(app)", json: json)
            throw ExitCode.failure
        }
        // Get close button
        var buttonVal: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &buttonVal) == .success else {
            JSONOutput.error("No close button found", json: json)
            throw ExitCode.failure
        }
        let button = buttonVal as! AXUIElement
        flashIndicatorIfRunning()
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        JSONOutput.print(["status": "ok", "message": "Closed \(app) window"], json: json)
    }
}

struct WindowMinimize: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "minimize", abstract: "Minimize window")

    @Argument(help: "App name (positional)") var appName: String?
    @Option(name: .long, help: "App name") var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let resolvedApp = app ?? appName else {
            JSONOutput.error("Provide app name as positional arg or --app", json: json)
            throw ExitCode.failure
        }

        guard let (_, _, windows) = getAppWindows(resolvedApp), let win = windows.first else {
            JSONOutput.error("No windows found for \(resolvedApp)", json: json)
            throw ExitCode.failure
        }
        flashIndicatorIfRunning()
        var buttonVal: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXMinimizeButtonAttribute as CFString, &buttonVal) == .success else {
            // Fallback: set minimized attribute directly
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFBoolean)
            JSONOutput.print(["status": "ok", "message": "Minimized \(resolvedApp)"], json: json)
            return
        }
        let button = buttonVal as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        JSONOutput.print(["status": "ok", "message": "Minimized \(resolvedApp)"], json: json)
    }
}

struct WindowFullscreen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fullscreen", abstract: "Toggle fullscreen")

    @Argument(help: "App name (positional)") var appName: String?
    @Option(name: .long, help: "App name") var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let resolvedApp = app ?? appName else {
            JSONOutput.error("Provide app name as positional arg or --app", json: json)
            throw ExitCode.failure
        }

        guard let (_, _, windows) = getAppWindows(resolvedApp), let win = windows.first else {
            JSONOutput.error("No windows found for \(resolvedApp)", json: json)
            throw ExitCode.failure
        }
        // Toggle AXFullScreen attribute
        var value: AnyObject?
        var isFullscreen = false
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &value) == .success {
            isFullscreen = (value as? Bool) ?? false
        }
        flashIndicatorIfRunning()
        AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (!isFullscreen) as CFBoolean)
        let state = !isFullscreen ? "entered" : "exited"
        JSONOutput.print(["status": "ok", "message": "\(resolvedApp) \(state) fullscreen"], json: json)
    }
}
