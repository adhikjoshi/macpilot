import ArgumentParser
import AppKit
import Foundation

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Wait/polling commands",
        subcommands: [WaitElement.self, WaitWindow.self, WaitSeconds.self]
    )
}

struct WaitElement: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "element", abstract: "Wait for UI element to appear")

    @Argument(help: "Text to search for") var query: String
    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long, help: "Timeout in seconds") var timeout: Double = 10
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = findAppPID(app) {
                let appElement = AXUIElementCreateApplication(pid)
                if findElement(appElement, matching: query, depth: 10) != nil {
                    JSONOutput.print(["status": "ok", "message": "Found '\(query)'", "found": true], json: json)
                    return
                }
            }
            usleep(200_000)
        }
        JSONOutput.error("Timeout waiting for '\(query)' after \(timeout)s", json: json)
        throw ExitCode.failure
    }
}

struct WaitWindow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "window", abstract: "Wait for app/window title to appear")

    @Argument(help: "App name or window title substring") var name: String
    @Option(name: .long, help: "Timeout in seconds") var timeout: Double = 10
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let match = findWindowMatch(query: name) {
                JSONOutput.print([
                    "status": "ok",
                    "message": "Window found: \(match.title) [\(match.app)]",
                    "found": true,
                    "app": match.app,
                    "title": match.title,
                ], json: json)
                return
            }
            usleep(200_000)
        }

        JSONOutput.error("Timeout waiting for window '\(name)' after \(timeout)s", json: json)
        throw ExitCode.failure
    }

    private func findWindowMatch(query: String) -> (app: String, title: String)? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        for app in apps {
            let appName = app.localizedName ?? ""

            if appName.localizedCaseInsensitiveContains(query) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                   let windows = value as? [AXUIElement], !windows.isEmpty {
                    let title = getAttr(windows[0], kAXTitleAttribute) ?? ""
                    return (app: appName, title: title)
                }
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                continue
            }

            for win in windows {
                let title = getAttr(win, kAXTitleAttribute) ?? ""
                if !title.isEmpty && title.localizedCaseInsensitiveContains(query) {
                    return (app: appName, title: title)
                }
            }
        }

        return nil
    }
}

struct WaitSeconds: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seconds", abstract: "Wait/sleep for N seconds")

    @Argument(help: "Seconds to wait") var duration: Double
    @Flag(name: .long) var json = false

    func run() {
        usleep(UInt32(duration * 1_000_000))
        JSONOutput.print(["status": "ok", "message": "Waited \(duration)s"], json: json)
    }
}
