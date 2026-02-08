import ArgumentParser
import AppKit
import CoreGraphics
import Foundation

struct Space: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Space/desktop management",
        subcommands: [SpaceList.self, SpaceSwitch.self, SpaceBring.self]
    )
}

// MARK: - CGS Private API declarations

// Connection to the window server
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int

@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ connection: Int, _ mask: Int) -> CFArray

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ connection: Int) -> Int

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ connection: Int, _ owner: Int, _ spaces: CFArray, _ options: Int, _ setTags: UnsafeMutablePointer<UInt64>?, _ clearTags: UnsafeMutablePointer<UInt64>?) -> CFArray?

// Space masks for CGSCopySpaces
let kCGSSpaceCurrent: Int = 5   // current space
let kCGSSpaceOther: Int = 6     // other spaces
let kCGSSpaceAll: Int = 7       // all spaces
let kCGSSpaceUser: Int = 1      // user spaces only

struct SpaceList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all Spaces/desktops")

    @Flag(name: .long) var json = false

    func run() throws {
        let conn = CGSMainConnectionID()
        let activeSpace = CGSGetActiveSpace(conn)

        // Get all user spaces
        let spacesRef = CGSCopySpaces(conn, kCGSSpaceAll)
        let spaces = spacesRef as? [Int] ?? []

        // Also get user-only spaces for filtering
        let userSpacesRef = CGSCopySpaces(conn, kCGSSpaceUser)
        let userSpaces = Set(userSpacesRef as? [Int] ?? [])

        var results: [[String: Any]] = []
        var index = 1
        for spaceID in spaces {
            let isUser = userSpaces.contains(spaceID)
            let isCurrent = spaceID == activeSpace
            let info: [String: Any] = [
                "id": spaceID,
                "index": index,
                "current": isCurrent,
                "type": isUser ? "user" : "system",
            ]
            results.append(info)
            index += 1
        }

        if json {
            JSONOutput.printArray(results, json: true)
        } else {
            for r in results {
                let id = r["id"] as? Int ?? 0
                let idx = r["index"] as? Int ?? 0
                let current = (r["current"] as? Bool ?? false) ? " (active)" : ""
                let type = r["type"] as? String ?? ""
                print("Space \(idx): id=\(id) type=\(type)\(current)")
            }
        }
    }
}

struct SpaceSwitch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "switch", abstract: "Switch to Space N or left/right")

    @Argument(help: "Direction (left/right) or index (1-9)") var target: String?
    @Option(name: .long, help: "Space index (1-based)") var index: Int?
    @Option(name: .long, help: "Direction: left or right") var direction: String?
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "Space switching")

        let resolvedDirection = direction ?? target.flatMap { value in
            let lowered = value.lowercased()
            return (lowered == "left" || lowered == "right") ? lowered : nil
        }
        let resolvedIndex = index ?? target.flatMap { Int($0) }

        if let dir = resolvedDirection {
            // Use Ctrl+Left/Right arrow — these are system shortcuts
            // Try AppleScript approach which is more reliable for system shortcuts
            let keyCode: String
            switch dir.lowercased() {
            case "left": keyCode = "123"   // left arrow
            case "right": keyCode = "124"  // right arrow
            default:
                JSONOutput.error("Direction must be 'left' or 'right'", json: json)
                throw ExitCode.failure
            }

            // Use AppleScript to trigger the key event (more reliable for system shortcuts)
            let script = """
            tell application "System Events"
                key code \(keyCode) using control down
            end tell
            """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let pipe = Pipe()
            task.standardError = pipe
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                flashIndicatorIfRunning()
                JSONOutput.print(["status": "ok", "message": "Switched Space \(dir)"], json: json)
            } else {
                // Fallback to CGEvent
                let code: UInt16 = dir.lowercased() == "left" ? 123 : 124
                let src = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
                down?.flags = .maskControl
                up?.flags = .maskControl
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                flashIndicatorIfRunning()
                JSONOutput.print(["status": "ok", "message": "Switched Space \(dir) (CGEvent fallback)"], json: json)
            }
            return
        }

        guard let index = resolvedIndex, index >= 1 && index <= 9 else {
            JSONOutput.error("Provide positional target (left/right or 1-9), --index (1-9), or --direction (left/right)", json: json)
            throw ExitCode.failure
        }

        // Use AppleScript for Ctrl+N (more reliable than CGEvent for system shortcuts)
        let keyCodes: [Int: Int] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25
        ]

        guard let keyCode = keyCodes[index] else {
            JSONOutput.error("Invalid index", json: json)
            throw ExitCode.failure
        }

        let script = """
        tell application "System Events"
            key code \(keyCode) using control down
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus == 0 {
            flashIndicatorIfRunning()
            JSONOutput.print(["status": "ok", "message": "Switched to Space \(index)"], json: json)
        } else {
            // Fallback to CGEvent
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: UInt16(keyCode), keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: UInt16(keyCode), keyDown: false)
            down?.flags = .maskControl
            up?.flags = .maskControl
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            flashIndicatorIfRunning()
            JSONOutput.print(["status": "ok", "message": "Switched to Space \(index) (CGEvent fallback)"], json: json)
        }
    }
}

struct SpaceBring: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bring", abstract: "Bring an app from any Space to the current one")

    @Option(name: .long, help: "App name") var app: String
    @Flag(name: .long) var json = false

    func run() throws {
        // 1. Find the app
        guard let runApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(app) == true
        }) else {
            JSONOutput.error("App '\(app)' not found", json: json)
            throw ExitCode.failure
        }

        let pid = runApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // First, check if we can already see windows (app on current Space)
        var value: AnyObject?
        var windows: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
           let w = value as? [AXUIElement], !w.isEmpty {
            windows = w
        }

        // Check if any windows are in fullscreen
        var hasFullscreenWindow = false
        for win in windows {
            var fsValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsValue) == .success,
               let isFS = fsValue as? Bool, isFS {
                hasFullscreenWindow = true
                break
            }
        }

        // If no windows visible via AX, or has fullscreen windows, need special handling
        if windows.isEmpty || hasFullscreenWindow {
            // Strategy: Activate app (switches to its Space), send Cmd+Ctrl+F or
            // use green button equivalent to exit fullscreen, wait, then it merges back

            // Activate the app - macOS switches to its fullscreen Space
            runApp.activate(options: [.activateAllWindows])
            usleep(800_000)

            // Re-fetch windows now that we're on the app's Space
            if windows.isEmpty {
                for _ in 0..<8 {
                    var v2: AnyObject?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &v2) == .success,
                       let w = v2 as? [AXUIElement], !w.isEmpty {
                        windows = w
                        break
                    }
                    usleep(300_000)
                }
            }

            // Exit fullscreen via AX attribute
            var exitedFullscreen = false
            for win in windows {
                var fsValue: AnyObject?
                if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsValue) == .success,
                   let isFS = fsValue as? Bool, isFS {
                    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, false as CFBoolean)
                    exitedFullscreen = true
                }
            }

            if !exitedFullscreen && windows.isEmpty {
                // Last resort: send keyboard shortcut to exit fullscreen
                // Cmd+Ctrl+F is the macOS standard fullscreen toggle
                let src = CGEventSource(stateID: .hidSystemState)
                // keycode 3 = 'f'
                let down = CGEvent(keyboardEventSource: src, virtualKey: 3, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 3, keyDown: false)
                down?.flags = [.maskCommand, .maskControl]
                up?.flags = [.maskCommand, .maskControl]
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                exitedFullscreen = true
            }

            if exitedFullscreen {
                // Wait for fullscreen exit animation
                usleep(1_800_000)
                // Re-fetch windows
                var v3: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &v3) == .success,
                   let w = v3 as? [AXUIElement], !w.isEmpty {
                    windows = w
                }
            }
        }

        // Move windows to visible area on current screen
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visibleFrame.maxY

        for win in windows {
            var point = CGPoint(x: visibleFrame.origin.x + 50, y: axY + 50)
            if let posValue = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
            }
        }

        // Activate the app
        runApp.activate(options: [.activateAllWindows])

        let msg = windows.isEmpty
            ? "Activated '\(runApp.localizedName ?? app)' (could not access windows)"
            : "Brought '\(runApp.localizedName ?? app)' to current space"
        flashIndicatorIfRunning()
        JSONOutput.print(["status": "ok", "message": msg, "windowCount": windows.count], json: json)
    }
}
