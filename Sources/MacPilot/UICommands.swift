import ArgumentParser
import AppKit
import Foundation

struct UI: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "UI element access via Accessibility API",
        subcommands: [UIList.self, UIFind.self, UIClick.self, UITree.self]
    )
}

struct UIList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List UI elements")

    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long, help: "Max depth") var depth: Int = 3
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        var elements: [[String: Any]] = []
        collectElements(appElement, depth: depth, current: 0, elements: &elements)

        if json {
            JSONOutput.printArray(elements, json: true)
        } else {
            for el in elements {
                let role = el["role"] as? String ?? ""
                let title = el["title"] as? String ?? ""
                let value = el["value"] as? String ?? ""
                let desc = el["description"] as? String ?? ""
                let label = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
                print("[\(role)] \(label)")
            }
        }
    }
}

struct UIFind: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find", abstract: "Find UI element by label/text")

    @Argument(help: "Text to search for") var query: String
    @Option(name: .long) var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        var elements: [[String: Any]] = []
        collectElements(appElement, depth: 8, current: 0, elements: &elements)

        let matches = elements.filter { el in
            let title = el["title"] as? String ?? ""
            let desc = el["description"] as? String ?? ""
            let value = el["value"] as? String ?? ""
            return title.localizedCaseInsensitiveContains(query) ||
                   desc.localizedCaseInsensitiveContains(query) ||
                   value.localizedCaseInsensitiveContains(query)
        }

        if json {
            JSONOutput.printArray(matches, json: true)
        } else {
            if matches.isEmpty {
                print("No elements found matching '\(query)'")
            } else {
                for el in matches {
                    let role = el["role"] as? String ?? ""
                    let title = el["title"] as? String ?? ""
                    let pos = el["position"] as? String ?? ""
                    let size = el["size"] as? String ?? ""
                    print("[\(role)] \(title)  pos=\(pos) size=\(size)")
                }
            }
        }
    }
}

struct UIClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click UI element by label")

    @Argument(help: "Label text of element to click") var label: String
    @Option(name: .long) var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        if let element = findElement(appElement, matching: label, depth: 8) {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            JSONOutput.print(["status": "ok", "message": "Clicked '\(label)'"], json: json)
        } else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }
    }
}

struct UITree: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tree", abstract: "Print accessibility tree")

    @Option(name: .long) var app: String?
    @Option(name: [.long, .customLong("max-depth")]) var depth: Int = 5
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        let tree: [String: Any] = buildTree(appElement, depth: depth, current: 0)

        if json {
            if let data = try? JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printTree(appElement, depth: depth, current: 0, indent: 0)
        }
    }

    private func printTree(_ element: AXUIElement, depth: Int, current: Int, indent: Int) {
        guard current < depth else { return }
        let prefix = String(repeating: "  ", count: indent)
        let role = getAttr(element, kAXRoleAttribute) ?? "?"
        let title = getAttr(element, kAXTitleAttribute) ?? ""
        let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
        let label = [title, desc].filter { !$0.isEmpty }.joined(separator: " - ")
        print("\(prefix)[\(role)] \(label)")

        if let children = getChildren(element) {
            for child in children {
                printTree(child, depth: depth, current: current + 1, indent: indent + 1)
            }
        }
    }

    private func buildTree(_ element: AXUIElement, depth: Int, current: Int) -> [String: Any] {
        var node: [String: Any] = [:]
        node["role"] = getAttr(element, kAXRoleAttribute) ?? ""
        node["title"] = getAttr(element, kAXTitleAttribute) ?? ""
        node["description"] = getAttr(element, kAXDescriptionAttribute) ?? ""

        if current < depth, let children = getChildren(element) {
            node["children"] = children.map { buildTree($0, depth: depth, current: current + 1) }
        }
        return node
    }
}

// MARK: - AX Helpers

func getAttr(_ element: AXUIElement, _ attr: String) -> String? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    guard result == .success else { return nil }
    if let str = value as? String { return str }
    return nil
}

func getPosition(_ element: AXUIElement) -> CGPoint? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success else { return nil }
    var point = CGPoint.zero
    if AXValueGetValue(value as! AXValue, .cgPoint, &point) { return point }
    return nil
}

func getSize(_ element: AXUIElement) -> CGSize? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success else { return nil }
    var size = CGSize.zero
    if AXValueGetValue(value as! AXValue, .cgSize, &size) { return size }
    return nil
}

func getChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? [AXUIElement]
}

func collectElements(_ element: AXUIElement, depth: Int, current: Int, elements: inout [[String: Any]]) {
    guard current < depth else { return }
    let role = getAttr(element, kAXRoleAttribute) ?? ""
    let title = getAttr(element, kAXTitleAttribute) ?? ""
    let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
    let val = getAttr(element, kAXValueAttribute) ?? ""
    let pos = getPosition(element)
    let sz = getSize(element)

    var dict: [String: Any] = [
        "role": role,
        "title": title,
        "description": desc,
        "value": val,
    ]
    if let p = pos { dict["position"] = "\(Int(p.x)),\(Int(p.y))" }
    if let s = sz { dict["size"] = "\(Int(s.width))x\(Int(s.height))" }

    if !role.isEmpty { elements.append(dict) }

    if let children = getChildren(element) {
        for child in children {
            collectElements(child, depth: depth, current: current + 1, elements: &elements)
        }
    }
}

func findElement(_ element: AXUIElement, matching query: String, depth: Int, current: Int = 0) -> AXUIElement? {
    guard current < depth else { return nil }
    let title = getAttr(element, kAXTitleAttribute) ?? ""
    let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
    if title.localizedCaseInsensitiveContains(query) || desc.localizedCaseInsensitiveContains(query) {
        return element
    }
    if let children = getChildren(element) {
        for child in children {
            if let found = findElement(child, matching: query, depth: depth, current: current + 1) {
                return found
            }
        }
    }
    return nil
}

func findAppPID(_ name: String?) -> pid_t? {
    if let name = name {
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) {
            return app.processIdentifier
        }
        return nil
    } else {
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
