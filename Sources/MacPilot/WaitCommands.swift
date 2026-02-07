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
            usleep(200_000) // 200ms
        }
        JSONOutput.error("Timeout waiting for '\(query)' after \(timeout)s", json: json)
        throw ExitCode.failure
    }
}

struct WaitWindow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "window", abstract: "Wait for window to appear")

    @Argument(help: "App or window title") var name: String
    @Option(name: .long, help: "Timeout in seconds") var timeout: Double = 10
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = findAppPID(name) {
                let appElement = AXUIElementCreateApplication(pid)
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                   let windows = value as? [AXUIElement], !windows.isEmpty {
                    let title = getAttr(windows[0], kAXTitleAttribute) ?? ""
                    JSONOutput.print(["status": "ok", "message": "Window found: \(title)", "found": true], json: json)
                    return
                }
            }
            usleep(200_000)
        }
        JSONOutput.error("Timeout waiting for window '\(name)' after \(timeout)s", json: json)
        throw ExitCode.failure
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
