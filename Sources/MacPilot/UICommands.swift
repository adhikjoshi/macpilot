import ArgumentParser
import AppKit
import Foundation

struct UI: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "UI element access via Accessibility API",
        subcommands: [
            UIList.self, UIFind.self, UIFindText.self, UIWaitFor.self,
            UIClick.self, UITree.self,
            UISetValue.self, UIGetValue.self, UISetFocus.self,
            UIScroll.self, UIAttributes.self,
            UIElementsAt.self, UIShortcuts.self,
        ]
    )
}

// MARK: - Existing Commands (with improvements K, L, O)

struct UIList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List UI elements")

    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long, help: "Max depth") var depth: Int = 3
    @Option(name: .long, help: "Filter by role (e.g. AXButton, AXTextField)") var role: String?
    @Flag(name: .long, help: "Preserve parent-child hierarchy") var hierarchy = false
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        if hierarchy && json {
            let tree = buildHierarchy(appElement, depth: depth, current: 0, roleFilter: role)
            if let data = try? JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        var elements: [[String: Any]] = []
        collectElements(appElement, depth: depth, current: 0, elements: &elements)

        let filtered = role == nil ? elements : elements.filter { el in
            let elRole = el["role"] as? String ?? ""
            return elRole.localizedCaseInsensitiveContains(role!)
        }

        if json {
            JSONOutput.printArray(filtered, json: true)
        } else {
            for el in filtered {
                let r = el["role"] as? String ?? ""
                let title = el["title"] as? String ?? ""
                let value = el["value"] as? String ?? ""
                let desc = el["description"] as? String ?? ""
                let label = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
                print("[\(r)] \(label)")
            }
        }
    }

    private func buildHierarchy(_ element: AXUIElement, depth: Int, current: Int, roleFilter: String?) -> [String: Any] {
        var node: [String: Any] = [:]
        let r = getAttr(element, kAXRoleAttribute) ?? ""
        node["role"] = r
        node["title"] = getAttr(element, kAXTitleAttribute) ?? ""
        node["description"] = getAttr(element, kAXDescriptionAttribute) ?? ""
        node["value"] = getAttr(element, kAXValueAttribute) ?? ""
        if let p = getPosition(element) { node["x"] = Int(p.x); node["y"] = Int(p.y) }
        if let s = getSize(element) { node["width"] = Int(s.width); node["height"] = Int(s.height) }

        if current < depth, let children = getChildren(element) {
            let childNodes = children.map { buildHierarchy($0, depth: depth, current: current + 1, roleFilter: roleFilter) }
            if let roleFilter = roleFilter {
                node["children"] = childNodes.filter { child in
                    let childRole = child["role"] as? String ?? ""
                    return childRole.localizedCaseInsensitiveContains(roleFilter) ||
                        (child["children"] as? [[String: Any]])?.isEmpty == false
                }
            } else {
                node["children"] = childNodes
            }
        }
        return node
    }
}

struct UIFind: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find", abstract: "Find UI element by label/text")

    @Argument(help: "Text to search for") var query: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role (e.g. AXButton)") var role: String?
    @Flag(name: .long, help: "Require exact text match") var exact = false
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
            let elRole = el["role"] as? String ?? ""

            if let role = role, !elRole.localizedCaseInsensitiveContains(role) {
                return false
            }

            if exact {
                return title == query || desc == query || value == query
            }
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
                    let r = el["role"] as? String ?? ""
                    let title = el["title"] as? String ?? ""
                    let pos = el["position"] as? String ?? ""
                    let size = el["size"] as? String ?? ""
                    print("[\(r)] \(title)  pos=\(pos) size=\(size)")
                }
            }
        }
    }
}

struct UIFindText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find-text", abstract: "Find first UI element containing text")

    @Argument(help: "Text to search for") var query: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role") var role: String?
    @Flag(name: .long, help: "Require exact match") var exact = false
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: query, depth: 12, exactMatch: exact, role: role) else {
            JSONOutput.error("No elements found matching '\(query)'", json: json)
            throw ExitCode.failure
        }

        let r = getAttr(element, kAXRoleAttribute) ?? ""
        let title = getAttr(element, kAXTitleAttribute) ?? ""
        let value = getAttr(element, kAXValueAttribute) ?? ""
        let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
        let pos = getPosition(element)
        let size = getSize(element)

        let payload: [String: Any] = [
            "status": "ok",
            "query": query,
            "role": r,
            "title": title,
            "value": value,
            "description": desc,
            "x": Int(pos?.x ?? 0),
            "y": Int(pos?.y ?? 0),
            "width": Int(size?.width ?? 0),
            "height": Int(size?.height ?? 0),
            "message": "Found matching element",
        ]

        if json {
            JSONOutput.print(payload, json: true)
        } else {
            print("[\(r)] \(title.isEmpty ? value : title) @ (\(Int(pos?.x ?? 0)),\(Int(pos?.y ?? 0)))")
        }
    }
}

struct UIWaitFor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait-for", abstract: "Wait for UI element text to appear")

    @Argument(help: "Text to wait for") var query: String
    @Option(name: .long, help: "App name") var app: String?
    @Option(name: .long, help: "Timeout in seconds") var timeout: Double = 10
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = findAppPID(app) {
                let appElement = AXUIElementCreateApplication(pid)
                if findElement(appElement, matching: query, depth: 12) != nil {
                    JSONOutput.print([
                        "status": "ok",
                        "message": "Found '\(query)'",
                        "found": true,
                    ], json: json)
                    return
                }
            }
            usleep(200_000)
        }

        JSONOutput.error("Timeout waiting for '\(query)' after \(timeout)s", json: json)
        throw ExitCode.failure
    }
}

struct UIClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click UI element by label")

    @Argument(help: "Label text of element to click") var label: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role (e.g. AXButton)") var role: String?
    @Flag(name: .long, help: "Require exact text match") var exact = false
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        if let element = findElementAdvanced(appElement, matching: label, depth: 8, exactMatch: exact, role: role) {
            flashIndicatorIfRunning()
            let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)

            if pressResult != .success {
                if let pos = getPosition(element), let size = getSize(element) {
                    let centerX = pos.x + size.width / 2
                    let centerY = pos.y + size.height / 2
                    MouseController.click(x: Double(centerX), y: Double(centerY))
                    JSONOutput.print(["status": "ok", "message": "Clicked '\(label)' via coordinates (\(Int(centerX)),\(Int(centerY)))"], json: json)
                    return
                }
                JSONOutput.error("Failed to click '\(label)' (AXPress failed, no position available)", json: json)
                throw ExitCode.failure
            }
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
        let r = getAttr(element, kAXRoleAttribute) ?? "?"
        let title = getAttr(element, kAXTitleAttribute) ?? ""
        let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
        let label = [title, desc].filter { !$0.isEmpty }.joined(separator: " - ")
        print("\(prefix)[\(r)] \(label)")

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

// MARK: - New Commands

struct UISetValue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-value", abstract: "Set value of a UI element (text field, checkbox, etc.)")

    @Argument(help: "Element label/text to find") var label: String
    @Argument(help: "Value to set") var value: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role") var role: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: label, depth: 10, role: role) else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        // Try direct AX value set first
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if result == .success {
            JSONOutput.print(["status": "ok", "message": "Set value of '\(label)' to '\(value)'", "method": "direct"], json: json)
            return
        }

        // Fallback: focus element, select all, type new value
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        usleep(100_000)
        KeyboardController.pressCombo("cmd+a")
        usleep(50_000)
        KeyboardController.typeText(value)
        JSONOutput.print(["status": "ok", "message": "Set value of '\(label)' via keyboard", "method": "keyboard"], json: json)
    }
}

struct UIGetValue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-value", abstract: "Get current value of a UI element")

    @Argument(help: "Element label/text to find") var label: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role") var role: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: label, depth: 10, role: role) else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }

        let elRole = getAttr(element, kAXRoleAttribute) ?? ""
        let title = getAttr(element, kAXTitleAttribute) ?? ""
        let value = getAttr(element, kAXValueAttribute) ?? ""
        let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
        let enabled = getBoolAttr(element, kAXEnabledAttribute)

        var payload: [String: Any] = [
            "status": "ok",
            "role": elRole,
            "title": title,
            "value": value,
            "description": desc,
            "label": label,
        ]
        if let enabled = enabled { payload["enabled"] = enabled }

        // Check for specific roles
        if elRole == "AXCheckBox" || elRole == "AXRadioButton" {
            let numVal = getNumberAttr(element, kAXValueAttribute)?.intValue ?? 0
            payload["checked"] = numVal == 1
        }
        if let pos = getPosition(element) { payload["x"] = Int(pos.x); payload["y"] = Int(pos.y) }
        if let sz = getSize(element) { payload["width"] = Int(sz.width); payload["height"] = Int(sz.height) }

        if json {
            JSONOutput.print(payload, json: true)
        } else {
            let display = value.isEmpty ? title : value
            print("[\(elRole)] \(label): \(display)")
        }
    }
}

struct UISetFocus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-focus", abstract: "Focus a UI element (e.g. text field)")

    @Argument(help: "Element label/text") var label: String
    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Filter by role") var role: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: label, depth: 10, role: role) else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        if result == .success {
            JSONOutput.print(["status": "ok", "message": "Focused '\(label)'"], json: json)
        } else {
            // Fallback: click the element to focus it
            if let pos = getPosition(element), let size = getSize(element) {
                let centerX = pos.x + size.width / 2
                let centerY = pos.y + size.height / 2
                MouseController.click(x: Double(centerX), y: Double(centerY))
                JSONOutput.print(["status": "ok", "message": "Focused '\(label)' via click"], json: json)
            } else {
                JSONOutput.error("Failed to focus '\(label)'", json: json)
                throw ExitCode.failure
            }
        }
    }
}

struct UIScroll: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll within a UI element")

    @Argument(help: "Element label/text to scroll within") var label: String
    @Argument(help: "Direction: up, down, left, right") var direction: String
    @Argument(help: "Amount (scroll clicks)") var amount: Int32 = 3
    @Option(name: .long) var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: label, depth: 10) else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }

        guard let pos = getPosition(element), let size = getSize(element) else {
            JSONOutput.error("Cannot determine element position for scrolling", json: json)
            throw ExitCode.failure
        }

        // Move mouse to center of element, then scroll
        let centerX = pos.x + size.width / 2
        let centerY = pos.y + size.height / 2

        flashIndicatorIfRunning()
        MouseController.move(x: Double(centerX), y: Double(centerY))
        usleep(50_000)
        MouseController.scroll(direction: direction, amount: amount)

        JSONOutput.print(["status": "ok", "message": "Scrolled \(direction) by \(amount) in '\(label)'"], json: json)
    }
}

struct UIAttributes: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attributes", abstract: "List all accessibility attributes of an element")

    @Argument(help: "Element label/text") var label: String
    @Option(name: .long) var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElementAdvanced(appElement, matching: label, depth: 10) else {
            JSONOutput.error("Element '\(label)' not found", json: json)
            throw ExitCode.failure
        }

        let attrNames = getAttributeNames(element)
        let actionNames = getActionNames(element)

        var attributes: [[String: Any]] = []
        for name in attrNames {
            var info: [String: Any] = ["name": name]
            if let val = getAnyAttr(element, name) {
                if let str = val as? String { info["value"] = str }
                else if let num = val as? NSNumber { info["value"] = num }
                else if let bool = val as? Bool { info["value"] = bool }
                else { info["type"] = String(describing: type(of: val)) }
            }
            attributes.append(info)
        }

        if json {
            JSONOutput.print([
                "status": "ok",
                "label": label,
                "attributeCount": attrNames.count,
                "actionCount": actionNames.count,
                "attributes": attributes,
                "actions": actionNames,
            ], json: true)
        } else {
            print("Attributes for '\(label)' (\(attrNames.count) attrs, \(actionNames.count) actions):")
            for attr in attributes {
                let name = attr["name"] as? String ?? ""
                if let val = attr["value"] {
                    print("  \(name) = \(val)")
                } else if let t = attr["type"] as? String {
                    print("  \(name) [\(t)]")
                } else {
                    print("  \(name)")
                }
            }
            if !actionNames.isEmpty {
                print("Actions: \(actionNames.joined(separator: ", "))")
            }
        }
    }
}

struct UIElementsAt: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elements-at",
        abstract: "Find all UI elements at or near screen coordinates"
    )

    @Argument(help: "Screen X coordinate") var x: Int
    @Argument(help: "Screen Y coordinate") var y: Int
    @Option(name: .long, help: "Search radius in pixels (default 30)") var radius: Int = 30
    @Option(name: .long, help: "App name (default: frontmost)") var app: String?
    @Option(name: .long, help: "Max AX tree depth") var depth: Int = 10
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        // Method 1: Use AXUIElementCopyElementAtPosition for the exact hit
        var hitElement: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &hitElement)

        var results: [[String: Any]] = []

        if hitResult == .success, let hit = hitElement {
            let entry = elementToDict(hit, source: "hit")
            results.append(entry)

            // Also get the parent's children to find siblings (nearby elements)
            var parentRef: AnyObject?
            if AXUIElementCopyAttributeValue(hit, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef as! AXUIElement? {
                if let siblings = getChildren(parent) {
                    for sibling in siblings {
                        if let pos = getPosition(sibling), let sz = getSize(sibling) {
                            let cx = pos.x + sz.width / 2
                            let cy = pos.y + sz.height / 2
                            let dx = abs(cx - CGFloat(x))
                            let dy = abs(cy - CGFloat(y))
                            if dx <= CGFloat(radius) || dy <= CGFloat(radius) {
                                let entry = elementToDict(sibling, source: "nearby")
                                if !results.contains(where: { ($0["x"] as? Int) == (entry["x"] as? Int) && ($0["y"] as? Int) == (entry["y"] as? Int) && ($0["role"] as? String) == (entry["role"] as? String) }) {
                                    results.append(entry)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Method 2: Deep scan — collect all elements and filter by proximity
        var allElements: [[String: Any]] = []
        collectElements(appElement, depth: depth, current: 0, elements: &allElements)

        for el in allElements {
            guard let posStr = el["position"] as? String else { continue }
            let parts = posStr.split(separator: ",")
            guard parts.count == 2, let ex = Int(parts[0]), let ey = Int(parts[1]) else { continue }
            guard let sizeStr = el["size"] as? String else { continue }
            let sizeParts = sizeStr.split(separator: "x")
            guard sizeParts.count == 2, let ew = Int(sizeParts[0]), let eh = Int(sizeParts[1]) else { continue }

            // Check if the point is inside the element or within radius
            let insideX = x >= ex - radius && x <= ex + ew + radius
            let insideY = y >= ey - radius && y <= ey + eh + radius
            guard insideX && insideY else { continue }

            let role = el["role"] as? String ?? ""
            let title = el["title"] as? String ?? ""
            let desc = el["description"] as? String ?? ""
            let value = el["value"] as? String ?? ""

            let distance = Int(sqrt(Double((x - ex - ew/2) * (x - ex - ew/2) + (y - ey - eh/2) * (y - ey - eh/2))))

            let entry: [String: Any] = [
                "role": role,
                "title": title,
                "description": desc,
                "value": value,
                "x": ex,
                "y": ey,
                "width": ew,
                "height": eh,
                "centerX": ex + ew / 2,
                "centerY": ey + eh / 2,
                "distance": distance,
                "source": "scan",
            ]

            if !results.contains(where: { ($0["x"] as? Int) == ex && ($0["y"] as? Int) == ey && ($0["role"] as? String) == role }) {
                results.append(entry)
            }
        }

        // Sort by distance
        results.sort { ($0["distance"] as? Int ?? 9999) < ($1["distance"] as? Int ?? 9999) }

        flashIndicatorIfRunning()

        if json {
            JSONOutput.printArray(results, json: true)
        } else {
            if results.isEmpty {
                print("No elements found near (\(x), \(y))")
            } else {
                for el in results {
                    let r = el["role"] as? String ?? ""
                    let title = el["title"] as? String ?? ""
                    let desc = el["description"] as? String ?? ""
                    let cx = el["centerX"] as? Int ?? 0
                    let cy = el["centerY"] as? Int ?? 0
                    let dist = el["distance"] as? Int ?? 0
                    let label = [title, desc].filter { !$0.isEmpty }.joined(separator: " | ")
                    print("[\(r)] \(label.isEmpty ? "(no label)" : label)  center=(\(cx),\(cy)) dist=\(dist)px")
                }
            }
        }
    }

    private func elementToDict(_ element: AXUIElement, source: String) -> [String: Any] {
        let role = getAttr(element, kAXRoleAttribute) ?? ""
        let title = getAttr(element, kAXTitleAttribute) ?? ""
        let desc = getAttr(element, kAXDescriptionAttribute) ?? ""
        let value = getAttr(element, kAXValueAttribute) ?? ""
        let pos = getPosition(element) ?? .zero
        let sz = getSize(element) ?? .zero
        let ex = Int(pos.x)
        let ey = Int(pos.y)
        let ew = Int(sz.width)
        let eh = Int(sz.height)
        let distance = Int(sqrt(Double((x - ex - ew/2) * (x - ex - ew/2) + (y - ey - eh/2) * (y - ey - eh/2))))

        // Get available actions
        var actionNamesRef: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionNamesRef) == .success, let names = actionNamesRef as? [String] {
            actions = names
        }

        return [
            "role": role,
            "title": title,
            "description": desc,
            "value": value,
            "x": ex,
            "y": ey,
            "width": ew,
            "height": eh,
            "centerX": ex + ew / 2,
            "centerY": ey + eh / 2,
            "distance": distance,
            "source": source,
            "actions": actions,
        ]
    }
}

struct UIShortcuts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shortcuts",
        abstract: "List all keyboard shortcuts for an app (reads menu bar)"
    )

    @Option(name: .long, help: "App name (default: frontmost)") var app: String?
    @Option(name: .long, help: "Filter by menu name (e.g. File, Edit)") var menu: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef as! AXUIElement? else {
            JSONOutput.error("Could not access menu bar", json: json)
            throw ExitCode.failure
        }

        var shortcuts: [[String: Any]] = []
        guard let topMenus = getChildren(menuBar) else {
            JSONOutput.print(["status": "ok", "shortcuts": [], "message": "No menus found"], json: json)
            return
        }

        for topMenu in topMenus {
            let menuTitle = getAttr(topMenu, kAXTitleAttribute) ?? ""
            if menuTitle == "Apple" { continue }
            if let filter = menu, !menuTitle.localizedCaseInsensitiveContains(filter) { continue }

            // Get the submenu
            var submenuRef: AnyObject?
            let hasSubmenu = AXUIElementCopyAttributeValue(topMenu, "AXChildren" as CFString, &submenuRef) == .success
            if hasSubmenu, let children = submenuRef as? [AXUIElement] {
                for child in children {
                    collectShortcuts(child, menuPath: menuTitle, shortcuts: &shortcuts)
                }
            }
        }

        flashIndicatorIfRunning()

        if json {
            let result: [String: Any] = [
                "status": "ok",
                "app": NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.localizedName ?? (app ?? "frontmost"),
                "count": shortcuts.count,
                "shortcuts": shortcuts,
            ]
            JSONOutput.print(result, json: true)
        } else {
            if shortcuts.isEmpty {
                print("No keyboard shortcuts found")
            } else {
                for s in shortcuts {
                    let path = s["menuPath"] as? String ?? ""
                    let key = s["shortcut"] as? String ?? ""
                    let title = s["title"] as? String ?? ""
                    print("\(key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(path) > \(title)")
                }
            }
        }
    }

    private func collectShortcuts(_ element: AXUIElement, menuPath: String, shortcuts: inout [[String: Any]]) {
        guard let items = getChildren(element) else { return }
        for item in items {
            let role = getAttr(item, kAXRoleAttribute) ?? ""
            let title = getAttr(item, kAXTitleAttribute) ?? ""

            if role == "AXMenuItem" || role == "AXMenuBarItem" {
                // Check for keyboard shortcut
                let cmdChar = getAttr(item, "AXMenuItemCmdChar") ?? ""
                var modifiers: UInt32 = 0
                var modRef: AnyObject?
                if AXUIElementCopyAttributeValue(item, "AXMenuItemCmdModifiers" as CFString, &modRef) == .success {
                    if let num = modRef as? NSNumber {
                        modifiers = num.uint32Value
                    }
                }

                if !cmdChar.isEmpty {
                    let modStr = modifiersString(modifiers)
                    let shortcut = "\(modStr)\(cmdChar)"
                    shortcuts.append([
                        "title": title,
                        "shortcut": shortcut,
                        "menuPath": menuPath,
                        "key": cmdChar,
                        "modifiers": modStr,
                    ])
                }

                // Recurse into submenus
                var subRef: AnyObject?
                if AXUIElementCopyAttributeValue(item, "AXChildren" as CFString, &subRef) == .success,
                   let subChildren = subRef as? [AXUIElement] {
                    for subChild in subChildren {
                        collectShortcuts(subChild, menuPath: "\(menuPath) > \(title)", shortcuts: &shortcuts)
                    }
                }
            }
        }
    }

    private func modifiersString(_ mods: UInt32) -> String {
        // AXMenuItemCmdModifiers: 0=Cmd, 1=Cmd+Shift, 2=Cmd+Option, 4=Cmd+Ctrl, etc.
        // Bit 0: no Cmd (kAXMenuItemModifierNoCommand), Bit 1: Shift, Bit 2: Option, Bit 3: Ctrl
        var parts: [String] = []
        if mods & (1 << 2) != 0 { parts.append("ctrl+") }
        if mods & (1 << 1) != 0 { parts.append("opt+") }
        if mods & (1 << 0) != 0 { parts.append("shift+") }
        // Cmd is always present unless bit 3 is set
        if mods & (1 << 3) == 0 { parts.insert("cmd+", at: 0) }
        return parts.joined()
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
        "depth": current,
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
    let value = getAttr(element, kAXValueAttribute) ?? ""
    if title.localizedCaseInsensitiveContains(query) ||
        desc.localizedCaseInsensitiveContains(query) ||
        value.localizedCaseInsensitiveContains(query) {
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
