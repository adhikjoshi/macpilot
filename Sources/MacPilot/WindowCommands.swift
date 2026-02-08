import ArgumentParser
import AppKit
import Foundation

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window management",
        subcommands: [WindowList.self, WindowFocus.self, WindowResize.self, WindowMove.self, WindowClose.self, WindowMinimize.self, WindowFullscreen.self]
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

private func windowInfo(_ win: AXUIElement) -> [String: Any] {
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
            guard let (_, _, windows) = getAppWindows(appName) else {
                JSONOutput.error("No windows found for \(appName)", json: json)
                throw ExitCode.failure
            }
            for win in windows {
                var info = windowInfo(win)
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
                    var info = windowInfo(win)
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
                print("\(app): \"\(title)\" (\(x),\(y) \(width)x\(height))")
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

        let resolvedTitle = getAttr(window, kAXTitleAttribute) ?? ""
        JSONOutput.print([
            "status": "ok",
            "message": "Focused window '\(resolvedTitle)' in \(runningApp.localizedName ?? resolvedApp)",
            "app": runningApp.localizedName ?? resolvedApp,
            "title": resolvedTitle,
        ], json: json)
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
        AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (!isFullscreen) as CFBoolean)
        let state = !isFullscreen ? "entered" : "exited"
        JSONOutput.print(["status": "ok", "message": "\(resolvedApp) \(state) fullscreen"], json: json)
    }
}
