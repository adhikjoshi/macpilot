import ArgumentParser
import AppKit
import Foundation

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window management",
        subcommands: [WindowList.self, WindowResize.self, WindowMove.self, WindowClose.self, WindowMinimize.self, WindowFullscreen.self]
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
    @Flag(name: .long) var json = false

    func run() throws {
        // If app specified, list that app's windows; otherwise list all regular apps' windows
        var results: [[String: Any]] = []

        if let appName = app {
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

struct WindowResize: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resize", abstract: "Resize window")

    @Option(name: .long, help: "App name") var app: String
    @Option(name: .long) var width: Double
    @Option(name: .long) var height: Double
    @Flag(name: .long) var json = false

    func run() throws {
        guard let (_, _, windows) = getAppWindows(app), let win = windows.first else {
            JSONOutput.error("No windows found for \(app)", json: json)
            throw ExitCode.failure
        }
        setSize(win, width: width, height: height)
        JSONOutput.print(["status": "ok", "message": "Resized \(app) to \(Int(width))x\(Int(height))"], json: json)
    }
}

struct WindowMove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move window")

    @Option(name: .long, help: "App name") var app: String
    @Option(name: .long) var x: Double
    @Option(name: .long) var y: Double
    @Flag(name: .long) var json = false

    func run() throws {
        guard let (_, _, windows) = getAppWindows(app), let win = windows.first else {
            JSONOutput.error("No windows found for \(app)", json: json)
            throw ExitCode.failure
        }
        setPosition(win, x: x, y: y)
        JSONOutput.print(["status": "ok", "message": "Moved \(app) to (\(Int(x)),\(Int(y)))"], json: json)
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

    @Option(name: .long, help: "App name") var app: String
    @Flag(name: .long) var json = false

    func run() throws {
        guard let (_, _, windows) = getAppWindows(app), let win = windows.first else {
            JSONOutput.error("No windows found for \(app)", json: json)
            throw ExitCode.failure
        }
        var buttonVal: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXMinimizeButtonAttribute as CFString, &buttonVal) == .success else {
            // Fallback: set minimized attribute directly
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFBoolean)
            JSONOutput.print(["status": "ok", "message": "Minimized \(app)"], json: json)
            return
        }
        let button = buttonVal as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        JSONOutput.print(["status": "ok", "message": "Minimized \(app)"], json: json)
    }
}

struct WindowFullscreen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fullscreen", abstract: "Toggle fullscreen")

    @Option(name: .long, help: "App name") var app: String
    @Flag(name: .long) var json = false

    func run() throws {
        guard let (_, _, windows) = getAppWindows(app), let win = windows.first else {
            JSONOutput.error("No windows found for \(app)", json: json)
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
        JSONOutput.print(["status": "ok", "message": "\(app) \(state) fullscreen"], json: json)
    }
}
