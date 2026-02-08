import ArgumentParser
import AppKit
import Foundation

struct Chrome: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chrome",
        abstract: "Chrome browser shortcuts",
        subcommands: [ChromeOpenURL.self, ChromeNewTab.self, ChromeCloseTab.self, ChromeExtensions.self, ChromeDevMode.self, ChromeListTabs.self]
    )
}

/// Helper to ensure Chrome is focused before sending keystrokes
private func focusChrome(json: Bool) throws {
    try requireActiveUserSession(json: json, actionDescription: "Chrome keyboard automation")

    guard let chrome = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.google.Chrome"
    }) else {
        JSONOutput.error("Google Chrome is not running", json: json)
        throw ExitCode.failure
    }

    chrome.activate(options: [.activateAllWindows])
    usleep(400_000)
}

private func listChromeTabs() throws -> [[String: Any]] {
    let fieldSep = String(UnicodeScalar(31))
    let rowSep = String(UnicodeScalar(30))

    let script = """
    tell application "Google Chrome"
        set fieldSep to character id 31
        set rowSep to character id 30
        set output to ""
        set windowIndex to 0
        repeat with w in windows
            set windowIndex to windowIndex + 1
            set tabIndex to 0
            repeat with t in tabs of w
                set tabIndex to tabIndex + 1
                set tabTitle to title of t
                set tabURL to URL of t
                set output to output & windowIndex & fieldSep & tabIndex & fieldSep & tabTitle & fieldSep & tabURL & rowSep
            end repeat
        end repeat
        return output
    end tell
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ValidationError(stderr.isEmpty ? "Failed to query Chrome tabs" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let trimmed = stdout.trimmingCharacters(in: .newlines)
    guard !trimmed.isEmpty else { return [] }

    var tabs: [[String: Any]] = []
    for row in trimmed.split(separator: Character(rowSep), omittingEmptySubsequences: true) {
        let fields = row.split(separator: Character(fieldSep), maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4 else { continue }
        tabs.append([
            "window": Int(fields[0]) ?? 0,
            "index": Int(fields[1]) ?? 0,
            "title": String(fields[2]),
            "url": String(fields[3]),
        ])
    }
    return tabs
}

struct ChromeOpenURL: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-url", abstract: "Open URL in current tab (Cmd+L, type, Return)")

    @Argument(help: "URL to open") var url: String
    @Flag(name: .long) var json = false

    func run() throws {
        try focusChrome(json: json)
        KeyboardController.pressCombo("cmd+l")
        usleep(200_000)
        KeyboardController.typeText(url)
        usleep(100_000)
        KeyboardController.pressCombo("return")
        JSONOutput.print(["status": "ok", "message": "Opened \(url) in Chrome"], json: json)
    }
}

struct ChromeNewTab: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new-tab", abstract: "Open URL in new tab (Cmd+T, type, Return)")

    @Argument(help: "URL to open") var url: String
    @Flag(name: .long) var json = false

    func run() throws {
        try focusChrome(json: json)
        KeyboardController.pressCombo("cmd+t")
        usleep(300_000)
        KeyboardController.typeText(url)
        usleep(100_000)
        KeyboardController.pressCombo("return")
        JSONOutput.print(["status": "ok", "message": "Opened \(url) in new Chrome tab"], json: json)
    }
}

struct ChromeCloseTab: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close-tab", abstract: "Close current Chrome tab (Cmd+W)")

    @Flag(name: .long) var json = false

    func run() throws {
        try focusChrome(json: json)
        KeyboardController.pressCombo("cmd+w")
        JSONOutput.print(["status": "ok", "message": "Closed current Chrome tab"], json: json)
    }
}

struct ChromeExtensions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "extensions", abstract: "Navigate to chrome://extensions")

    @Flag(name: .long) var json = false

    func run() throws {
        try focusChrome(json: json)
        KeyboardController.pressCombo("cmd+l")
        usleep(200_000)
        KeyboardController.typeText("chrome://extensions")
        usleep(100_000)
        KeyboardController.pressCombo("return")
        JSONOutput.print(["status": "ok", "message": "Navigated to chrome://extensions"], json: json)
    }
}

struct ChromeDevMode: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dev-mode", abstract: "Toggle developer mode in chrome://extensions")

    @Flag(name: .long) var json = false

    func run() throws {
        try focusChrome(json: json)
        // Navigate to extensions page first
        KeyboardController.pressCombo("cmd+l")
        usleep(200_000)
        KeyboardController.typeText("chrome://extensions")
        usleep(100_000)
        KeyboardController.pressCombo("return")
        usleep(1_500_000) // Wait for page to load

        // Tab to developer mode toggle and press Space
        // The developer mode toggle is typically reachable via Tab from the main content
        KeyboardController.pressCombo("tab")
        usleep(200_000)
        KeyboardController.pressCombo("space")
        JSONOutput.print(["status": "ok", "message": "Toggled developer mode"], json: json)
    }
}

struct ChromeListTabs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-tabs", abstract: "List open Chrome tabs")

    @Flag(name: .long) var json = false

    func run() throws {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
            JSONOutput.error("Google Chrome is not running", json: json)
            throw ExitCode.failure
        }

        let tabs: [[String: Any]]
        do {
            tabs = try listChromeTabs()
        } catch {
            JSONOutput.error(error.localizedDescription, json: json)
            throw ExitCode.failure
        }

        if json {
            JSONOutput.print([
                "status": "ok",
                "count": tabs.count,
                "tabs": tabs,
            ], json: true)
        } else if tabs.isEmpty {
            print("No tabs found")
        } else {
            for tab in tabs {
                let windowIndex = tab["window"] as? Int ?? 0
                let tabIndex = tab["index"] as? Int ?? 0
                let title = tab["title"] as? String ?? ""
                let url = tab["url"] as? String ?? ""
                print("[\(windowIndex):\(tabIndex)] \(title) - \(url)")
            }
        }
    }
}
