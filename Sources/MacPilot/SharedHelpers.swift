import AppKit
import CoreGraphics
import Foundation

// MARK: - Shared AppleScript Helpers (R: extracted from AppCommands + WindowCommands)

@discardableResult
func sharedRunAppleScript(_ source: String) -> Bool {
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

func sharedRunAppleScriptOutput(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

// MARK: - Shared Cmd+N Helper (R: extracted from AppCommands + WindowCommands)

func sharedSendCommandN() {
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

// MARK: - Extended AX Helpers (B, P: needed for get-value, attributes)

func getAnyAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    guard result == .success else { return nil }
    return value
}

func getNumberAttr(_ element: AXUIElement, _ attr: String) -> NSNumber? {
    getAnyAttr(element, attr) as? NSNumber
}

func getBoolAttr(_ element: AXUIElement, _ attr: String) -> Bool? {
    getAnyAttr(element, attr) as? Bool
}

func getAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
          let array = names as? [String] else {
        return []
    }
    return array
}

func getActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let array = names as? [String] else {
        return []
    }
    return array
}

// MARK: - Enhanced Element Search (K, L: exact match + role filter)

func findElementAdvanced(
    _ element: AXUIElement,
    matching query: String,
    depth: Int,
    current: Int = 0,
    exactMatch: Bool = false,
    role: String? = nil
) -> AXUIElement? {
    guard current < depth else { return nil }
    let elRole = getAttr(element, kAXRoleAttribute) ?? ""
    let title = getAttr(element, kAXTitleAttribute) ?? ""
    let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
    let value = getAttr(element, kAXValueAttribute) ?? ""

    // Role filter
    if let role = role, !role.isEmpty {
        if !elRole.localizedCaseInsensitiveContains(role) {
            // Still recurse into children
            if let children = getChildren(element) {
                for child in children {
                    if let found = findElementAdvanced(child, matching: query, depth: depth, current: current + 1, exactMatch: exactMatch, role: role) {
                        return found
                    }
                }
            }
            return nil
        }
    }

    // Text matching
    let matches: Bool
    if exactMatch {
        matches = title == query || desc == query || value == query
    } else {
        matches = title.localizedCaseInsensitiveContains(query) ||
            desc.localizedCaseInsensitiveContains(query) ||
            value.localizedCaseInsensitiveContains(query)
    }

    if matches { return element }

    if let children = getChildren(element) {
        for child in children {
            if let found = findElementAdvanced(child, matching: query, depth: depth, current: current + 1, exactMatch: exactMatch, role: role) {
                return found
            }
        }
    }
    return nil
}
