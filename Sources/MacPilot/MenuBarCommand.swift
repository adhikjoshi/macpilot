import ArgumentParser
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

private func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as! AXUIElement?
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func menuItemMatches(_ element: AXUIElement, query: String) -> Bool {
    let title = axStringAttribute(element, kAXTitleAttribute) ?? ""
    return title.localizedCaseInsensitiveContains(query)
}

private func findMenuItem(in container: AXUIElement, query: String) -> AXUIElement? {
    for child in axChildren(container) where menuItemMatches(child, query: query) {
        return child
    }
    return nil
}

private func clickMenuBarPath(appName: String, menuPath: String, json: Bool) throws {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
    }) else {
        JSONOutput.error("App not running: \(appName)", json: json)
        throw ExitCode.failure
    }

    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    usleep(220_000)

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let menuBar = axElementAttribute(appElement, kAXMenuBarAttribute) else {
        JSONOutput.error("Could not access menu bar for \(app.localizedName ?? appName)", json: json)
        throw ExitCode.failure
    }

    let segments = menuPath
        .split(separator: ">")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !segments.isEmpty else {
        JSONOutput.error("Menu path is empty. Example: \"File > New Window\"", json: json)
        throw ExitCode.failure
    }

    var currentContainer = menuBar

    for (index, segment) in segments.enumerated() {
        guard let item = findMenuItem(in: currentContainer, query: segment) else {
            JSONOutput.error("Menu item not found: \(segment)", json: json)
            throw ExitCode.failure
        }

        let isLast = index == segments.count - 1
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else {
            JSONOutput.error("Failed to click menu item '\(segment)'", json: json)
            throw ExitCode.failure
        }

        if isLast {
            flashIndicatorIfRunning()
            JSONOutput.print([
                "status": "ok",
                "message": "Clicked menu item \(menuPath) in \(app.localizedName ?? appName)",
                "app": app.localizedName ?? appName,
                "menuItem": menuPath,
            ], json: json)
            return
        }

        usleep(120_000)
        guard let submenu = axElementAttribute(item, "AXMenu") ?? axChildren(item).first else {
            JSONOutput.error("Submenu not available for '\(segment)'", json: json)
            throw ExitCode.failure
        }
        currentContainer = submenu
    }
}

struct MenuBar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menubar",
        abstract: "Menu bar commands",
        subcommands: [MenuBarStart.self, MenuBarClick.self]
    )
}

struct MenuBarStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure the MacPilot menu bar is running (via indicator)")

    @Flag(name: .long) var json = false

    func run() throws {
        ensureIndicatorAutoStartIfNeeded()
        let running = IndicatorClient.isRunning()
        JSONOutput.print([
            "status": "ok",
            "message": running ? "Menu bar is running (via indicator)" : "Could not start indicator",
            "running": running,
        ], json: json)
    }
}

struct MenuBarClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click a menu bar item in an app")

    @Argument(help: "Target app name") var appName: String
    @Argument(help: "Menu path, e.g. \"File > New Window\"") var menuItem: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "menu bar interaction")
        try clickMenuBarPath(appName: appName, menuPath: menuItem, json: json)
    }
}
