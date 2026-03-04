import ArgumentParser
import AppKit
import Foundation
import UserNotifications

struct NotificationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Notification center utilities",
        subcommands: [
            NotificationSend.self,
            NotificationList.self,
            NotificationClick.self,
            NotificationDismiss.self,
        ]
    )
}

struct NotificationSend: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Send a system notification")

    @Argument(help: "Notification title") var title: String
    @Argument(help: "Notification body") var body: String
    @Flag(name: .long) var json = false

    func run() throws {
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)

        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            semaphore.signal()
        }
        semaphore.wait()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        var deliveryError: Error?

        center.add(request) { error in
            deliveryError = error
            semaphore.signal()
        }
        semaphore.wait()

        flashIndicatorIfRunning()

        if let err = deliveryError {
            JSONOutput.error("Failed to send notification: \(err.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Notification sent",
            "title": title,
            "body": body,
        ], json: json)
    }
}

// MARK: - notification list

struct NotificationList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List visible notifications via AX")

    @Flag(name: .long) var json = false

    func run() throws {
        let notifications = collectNotificationElements()

        if json {
            JSONOutput.print([
                "status": "ok",
                "notifications": notifications,
                "count": notifications.count,
            ], json: true)
        } else {
            if notifications.isEmpty {
                print("No visible notifications")
            } else {
                for (i, n) in notifications.enumerated() {
                    let title = n["title"] as? String ?? ""
                    let body = n["body"] as? String ?? ""
                    let app = n["app"] as? String ?? ""
                    print("  [\(i + 1)] \(app): \(title) — \(body)")
                }
            }
        }
    }
}

// MARK: - notification click

struct NotificationClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click a notification matching title")

    @Option(name: .long, help: "Match notification by title (case-insensitive contains)") var title: String?
    @Flag(name: .long) var json = false

    func run() throws {
        let elements = findNotificationAXElements()
        let titleMatch = title?.lowercased()

        for (element, info) in elements {
            let notifTitle = info["title"] as? String ?? ""
            if let match = titleMatch {
                guard notifTitle.lowercased().contains(match) else { continue }
            }

            // Click the notification
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success {
                JSONOutput.print([
                    "status": "ok",
                    "message": "Clicked notification: \(notifTitle)",
                    "title": notifTitle,
                ], json: json)
                return
            }
        }

        // Fallback: try AppleScript
        if let titleMatch = title {
            let script = """
            tell application "System Events"
                tell process "NotificationCenter"
                    set notifWindows to every window
                    repeat with w in notifWindows
                        try
                            set notifTitle to value of static text 1 of w
                            if notifTitle contains "\(titleMatch)" then
                                click w
                                return "clicked"
                            end if
                        end try
                    end repeat
                end tell
            end tell
            return "not_found"
            """
            let result = sharedRunAppleScriptOutput(script) ?? "not_found"
            if result.contains("clicked") {
                JSONOutput.print([
                    "status": "ok",
                    "message": "Clicked notification matching '\(titleMatch)'",
                ], json: json)
                return
            }
        }

        JSONOutput.error("No matching notification found", json: json)
        throw ExitCode.failure
    }
}

// MARK: - notification dismiss

struct NotificationDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss notification(s)")

    @Flag(name: .long, help: "Dismiss all notifications") var all = false
    @Flag(name: .long) var json = false

    func run() throws {
        if all {
            // Use AppleScript to dismiss all
            let script = """
            tell application "System Events"
                tell process "NotificationCenter"
                    set notifWindows to every window
                    set dismissed to 0
                    repeat with w in notifWindows
                        try
                            set actionNames to name of every action of w
                            if actionNames contains "AXDismiss" then
                                perform action "AXDismiss" of w
                                set dismissed to dismissed + 1
                            else
                                -- Try close button
                                set closeButtons to every button of w whose description contains "Close" or title contains "Close"
                                if (count of closeButtons) > 0 then
                                    click item 1 of closeButtons
                                    set dismissed to dismissed + 1
                                end if
                            end if
                        end try
                    end repeat
                    return dismissed as string
                end tell
            end tell
            """
            let result = sharedRunAppleScriptOutput(script) ?? "0"
            let count = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

            JSONOutput.print([
                "status": "ok",
                "message": "Dismissed \(count) notification(s)",
                "count": count,
            ], json: json)
        } else {
            // Dismiss the first/most recent notification
            let elements = findNotificationAXElements()
            guard let (element, info) = elements.first else {
                JSONOutput.error("No notifications to dismiss", json: json)
                throw ExitCode.failure
            }

            // Try AXDismiss action
            var dismissed = false
            let actions = getActionNames(element)
            if actions.contains("AXDismiss") {
                dismissed = AXUIElementPerformAction(element, "AXDismiss" as CFString) == .success
            }

            if !dismissed {
                // Fallback: AppleScript
                let script = """
                tell application "System Events"
                    tell process "NotificationCenter"
                        try
                            set w to first window
                            set actionNames to name of every action of w
                            if actionNames contains "AXDismiss" then
                                perform action "AXDismiss" of w
                            else
                                click w
                            end if
                        end try
                    end tell
                end tell
                """
                sharedRunAppleScript(script)
                dismissed = true
            }

            let title = info["title"] as? String ?? "notification"
            JSONOutput.print([
                "status": "ok",
                "message": "Dismissed \(title)",
            ], json: json)
        }
    }
}

// MARK: - AX helpers for Notification Center

private func collectNotificationElements() -> [[String: Any]] {
    let elements = findNotificationAXElements()
    return elements.map { $0.1 }
}

private func findNotificationAXElements() -> [(AXUIElement, [String: Any])] {
    var results: [(AXUIElement, [String: Any])] = []

    // Find NotificationCenter process
    guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.notificationcenterui" ||
        $0.localizedName == "NotificationCenter" ||
        $0.localizedName == "Notification Center"
    }) else {
        return results
    }

    let appElement = AXUIElementCreateApplication(ncApp.processIdentifier)

    // Get windows (each notification is typically a window)
    var windowsValue: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement] else {
        return results
    }

    for window in windows {
        var info: [String: Any] = [:]
        let texts = collectStaticTexts(window)

        if texts.count >= 2 {
            info["title"] = texts[0]
            info["body"] = texts[1]
        } else if texts.count == 1 {
            info["title"] = texts[0]
            info["body"] = ""
        } else {
            info["title"] = getAttr(window, kAXTitleAttribute) ?? ""
            info["body"] = getAttr(window, kAXDescriptionAttribute) ?? ""
        }

        // Try to get app name from subrole or description
        info["app"] = getAttr(window, kAXSubroleAttribute) ?? ""

        if let pos = getPosition(window) {
            info["x"] = Int(pos.x)
            info["y"] = Int(pos.y)
        }
        if let size = getSize(window) {
            info["width"] = Int(size.width)
            info["height"] = Int(size.height)
        }

        results.append((window, info))
    }

    return results
}

private func collectStaticTexts(_ element: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 8 else { return [] }
    var texts: [String] = []

    let role = getAttr(element, kAXRoleAttribute) ?? ""
    if role == "AXStaticText" {
        let value = getAttr(element, kAXValueAttribute) ?? getAttr(element, kAXTitleAttribute) ?? ""
        if !value.isEmpty { texts.append(value) }
    }

    if let children = getChildren(element) {
        for child in children {
            texts.append(contentsOf: collectStaticTexts(child, depth: depth + 1))
        }
    }

    return texts
}
