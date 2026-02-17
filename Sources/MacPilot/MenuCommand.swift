import ArgumentParser
import AppKit
import Foundation

// MARK: - Gap H: Menu bar navigation

struct Menu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "Menu bar navigation",
        subcommands: [MenuClick.self, MenuList.self]
    )
}

struct MenuClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click a menu item by path (e.g. menu click File Open)")

    @Argument(help: "Menu path, e.g. 'File' 'Open'") var path: [String]
    @Option(name: .long) var app: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard !path.isEmpty else {
            JSONOutput.error("Provide menu path, e.g.: menu click File Open", json: json)
            throw ExitCode.failure
        }
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success else {
            JSONOutput.error("Cannot access menu bar (is Accessibility granted?)", json: json)
            throw ExitCode.failure
        }

        var current = menuBarValue as! AXUIElement

        for (i, menuName) in path.enumerated() {
            guard let children = getChildren(current) else {
                JSONOutput.error("Menu item '\(menuName)' not found at level \(i)", json: json)
                throw ExitCode.failure
            }

            var found = false
            for child in children {
                let title = getAttr(child, kAXTitleAttribute) ?? ""
                if title.localizedCaseInsensitiveContains(menuName) || title == menuName {
                    if i == path.count - 1 {
                        // Last item — press it
                        flashIndicatorIfRunning()
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                        JSONOutput.print(["status": "ok", "message": "Clicked menu: \(path.joined(separator: " > "))"], json: json)
                        return
                    } else {
                        // Open submenu
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                        usleep(150_000)
                        // Navigate into submenu children
                        if let subChildren = getChildren(child) {
                            for sub in subChildren {
                                let subRole = getAttr(sub, kAXRoleAttribute) ?? ""
                                if subRole.contains("Menu") {
                                    current = sub
                                    found = true
                                    break
                                }
                            }
                            if !found {
                                current = child
                                found = true
                            }
                        } else {
                            current = child
                            found = true
                        }
                        break
                    }
                }
            }
            if !found {
                JSONOutput.error("Menu item '\(menuName)' not found at level \(i)", json: json)
                throw ExitCode.failure
            }
        }
    }
}

struct MenuList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List menu items of the frontmost or specified app")

    @Option(name: .long) var app: String?
    @Option(name: .long, help: "Specific top-level menu to expand") var menu: String?
    @Option(name: .long, help: "Max depth to traverse") var depth: Int = 2
    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = findAppPID(app) else {
            JSONOutput.error("App not found: \(app ?? "frontmost")", json: json)
            throw ExitCode.failure
        }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success else {
            JSONOutput.error("Cannot access menu bar", json: json)
            throw ExitCode.failure
        }

        let menuBar = menuBarValue as! AXUIElement
        guard let topItems = getChildren(menuBar) else {
            JSONOutput.error("No menu items found", json: json)
            throw ExitCode.failure
        }

        var results: [[String: Any]] = []
        for item in topItems {
            let title = getAttr(item, kAXTitleAttribute) ?? ""
            if title.isEmpty { continue }
            if let filterMenu = menu, !title.localizedCaseInsensitiveContains(filterMenu) {
                continue
            }

            var menuInfo: [String: Any] = ["title": title]
            var subItems: [[String: Any]] = []
            if let children = getChildren(item) {
                for child in children {
                    collectMenuItems(child, depth: 0, maxDepth: depth, items: &subItems)
                }
            }
            menuInfo["items"] = subItems
            results.append(menuInfo)
        }

        if json {
            JSONOutput.printArray(results, json: true)
        } else {
            for m in results {
                let title = m["title"] as? String ?? ""
                print("[\(title)]")
                if let items = m["items"] as? [[String: Any]] {
                    for item in items {
                        let itemTitle = item["title"] as? String ?? ""
                        let shortcut = item["shortcut"] as? String ?? ""
                        let d = item["depth"] as? Int ?? 0
                        let indent = String(repeating: "  ", count: d + 1)
                        let sc = shortcut.isEmpty ? "" : " (\(shortcut))"
                        print("\(indent)\(itemTitle)\(sc)")
                    }
                }
            }
        }
    }

    private func collectMenuItems(_ element: AXUIElement, depth: Int, maxDepth: Int, items: inout [[String: Any]]) {
        guard depth <= maxDepth else { return }
        let role = getAttr(element, kAXRoleAttribute) ?? ""
        let title = getAttr(element, kAXTitleAttribute) ?? ""

        if role.contains("MenuItem") && !title.isEmpty {
            var info: [String: Any] = ["title": title, "role": role, "depth": depth]
            if let shortcut = getAttr(element, "AXMenuItemCmdChar"), !shortcut.isEmpty {
                var mods = "Cmd+"
                if let modVal = getNumberAttr(element, "AXMenuItemCmdModifiers")?.intValue {
                    if modVal & 1 != 0 { mods = "Shift+" + mods }
                    if modVal & 2 != 0 { mods = "Opt+" + mods }
                    if modVal & 4 != 0 { mods = "Ctrl+" + mods }
                }
                info["shortcut"] = mods + shortcut
            }
            let enabled = getBoolAttr(element, kAXEnabledAttribute) ?? true
            info["enabled"] = enabled
            items.append(info)
        }

        if let children = getChildren(element) {
            for child in children {
                collectMenuItems(child, depth: depth + 1, maxDepth: maxDepth, items: &items)
            }
        }
    }
}
