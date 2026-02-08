import ArgumentParser
import AppKit
import Foundation

struct Chrome: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chrome",
        abstract: "Chrome browser shortcuts",
        subcommands: [ChromeOpenURL.self, ChromeNewTab.self, ChromeExtensions.self, ChromeDevMode.self]
    )
}

/// Helper to ensure Chrome is focused before sending keystrokes
private func focusChrome() {
    if let chrome = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.google.Chrome"
    }) {
        chrome.activate(options: [.activateAllWindows])
        usleep(400_000)
    }
}

struct ChromeOpenURL: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-url", abstract: "Open URL in current tab (Cmd+L, type, Return)")

    @Argument(help: "URL to open") var url: String
    @Flag(name: .long) var json = false

    func run() {
        focusChrome()
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

    func run() {
        focusChrome()
        KeyboardController.pressCombo("cmd+t")
        usleep(300_000)
        KeyboardController.typeText(url)
        usleep(100_000)
        KeyboardController.pressCombo("return")
        JSONOutput.print(["status": "ok", "message": "Opened \(url) in new Chrome tab"], json: json)
    }
}

struct ChromeExtensions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "extensions", abstract: "Navigate to chrome://extensions")

    @Flag(name: .long) var json = false

    func run() {
        focusChrome()
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

    func run() {
        focusChrome()
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
