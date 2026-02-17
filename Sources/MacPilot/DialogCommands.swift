import ArgumentParser
import AppKit
import ApplicationServices
import Foundation

// MARK: - Dialog AX Introspection Framework

/// Scan dialog AX tree and collect all interactive elements with their roles, values, and positions
private func scanDialogElements(_ root: AXUIElement, depth: Int = 0, maxDepth: Int = 15, parentPath: String = "") -> [[String: Any]] {
    guard depth < maxDepth else { return [] }
    var results: [[String: Any]] = []

    let role = getAttr(root, kAXRoleAttribute) ?? ""
    let title = getAttr(root, kAXTitleAttribute) ?? ""
    let desc = getAttr(root, kAXDescriptionAttribute) ?? ""
    let value = getAttr(root, kAXValueAttribute) ?? ""
    let subrole = getAttr(root, kAXSubroleAttribute) ?? ""
    let focused = getBoolAttr(root, kAXFocusedAttribute) ?? false
    let enabled = getBoolAttr(root, kAXEnabledAttribute) ?? true
    let actions = getActionNames(root)

    let isInteractive = !actions.isEmpty ||
        role.contains("TextField") || role.contains("ComboBox") ||
        role.contains("Button") || role.contains("PopUp") ||
        role.contains("CheckBox") || role.contains("List") ||
        role.contains("Table") || role.contains("Outline") ||
        role.contains("Browser")

    if isInteractive || role == "AXSheet" || role == "AXStaticText" {
        var entry: [String: Any] = [
            "role": role,
            "depth": depth,
        ]
        if !title.isEmpty { entry["title"] = title }
        if !desc.isEmpty { entry["description"] = desc }
        if !value.isEmpty && value.count < 200 { entry["value"] = value }
        if !subrole.isEmpty { entry["subrole"] = subrole }
        if focused { entry["focused"] = true }
        if !enabled { entry["enabled"] = false }
        if !actions.isEmpty { entry["actions"] = actions }

        if let pos = getPosition(root) {
            entry["x"] = Int(pos.x)
            entry["y"] = Int(pos.y)
        }
        if let size = getSize(root) {
            entry["width"] = Int(size.width)
            entry["height"] = Int(size.height)
        }

        results.append(entry)
    }

    if let children = getChildren(root) {
        for child in children {
            results.append(contentsOf: scanDialogElements(child, depth: depth + 1, maxDepth: maxDepth))
        }
    }

    return results
}

/// Find a text field/combo box by matching role, label, description, or value
private func findDialogField(
    _ root: AXUIElement,
    role: String? = nil,
    label: String? = nil,
    depth: Int = 0,
    maxDepth: Int = 15
) -> AXUIElement? {
    guard depth < maxDepth else { return nil }

    let elRole = getAttr(root, kAXRoleAttribute) ?? ""
    let elTitle = getAttr(root, kAXTitleAttribute) ?? ""
    let elDesc = getAttr(root, kAXDescriptionAttribute) ?? ""
    let roleMatch = role == nil || elRole.localizedCaseInsensitiveContains(role!)
    let labelMatch = label == nil ||
        elTitle.localizedCaseInsensitiveContains(label!) ||
        elDesc.localizedCaseInsensitiveContains(label!)

    // Check if this is an editable text element
    let isTextInput = elRole == "AXTextField" || elRole == "AXComboBox" || elRole == "AXTextArea"

    if isTextInput && roleMatch && labelMatch {
        return root
    }

    guard let children = getChildren(root) else { return nil }
    for child in children {
        if let found = findDialogField(child, role: role, label: label, depth: depth + 1, maxDepth: maxDepth) {
            return found
        }
    }
    return nil
}

/// Find a button by title or description
private func findDialogButtonElement(_ root: AXUIElement, label: String, depth: Int = 0, maxDepth: Int = 12) -> AXUIElement? {
    guard depth < maxDepth else { return nil }

    let elRole = getAttr(root, kAXRoleAttribute) ?? ""
    let elTitle = getAttr(root, kAXTitleAttribute) ?? ""
    let elDesc = getAttr(root, kAXDescriptionAttribute) ?? ""

    if (elRole == "AXButton" || elRole == "AXMenuItem") &&
       (elTitle.localizedCaseInsensitiveContains(label) || elDesc.localizedCaseInsensitiveContains(label)) {
        return root
    }

    guard let children = getChildren(root) else { return nil }
    for child in children {
        if let found = findDialogButtonElement(child, label: label, depth: depth + 1, maxDepth: maxDepth) {
            return found
        }
    }
    return nil
}

/// Collect file/row items visible in a dialog's file browser
private func collectDialogFileItems(_ root: AXUIElement, depth: Int = 0, maxDepth: Int = 12) -> [[String: Any]] {
    guard depth < maxDepth else { return [] }
    var items: [[String: Any]] = []

    let role = getAttr(root, kAXRoleAttribute) ?? ""

    // File items are typically AXRow, AXCell, or AXStaticText inside a table/outline/browser
    if role == "AXRow" || (role == "AXCell" && depth > 2) {
        let title = getAttr(root, kAXTitleAttribute) ?? ""
        let value = getAttr(root, kAXValueAttribute) ?? ""
        let desc = getAttr(root, kAXDescriptionAttribute) ?? ""
        let name = [title, value, desc].first(where: { !$0.isEmpty }) ?? ""

        if !name.isEmpty {
            var item: [String: Any] = ["name": name, "role": role]
            if let pos = getPosition(root) {
                item["x"] = Int(pos.x)
                item["y"] = Int(pos.y)
            }
            if let size = getSize(root) {
                item["width"] = Int(size.width)
                item["height"] = Int(size.height)
            }
            // Check if selected
            if let selected = getBoolAttr(root, kAXSelectedAttribute) {
                item["selected"] = selected
            }
            items.append(item)
        }
    }

    guard let children = getChildren(root) else { return items }
    for child in children {
        items.append(contentsOf: collectDialogFileItems(child, depth: depth + 1, maxDepth: maxDepth))
    }
    return items
}

/// Set value on an AX text element, then verify
private func setFieldValue(_ element: AXUIElement, value: String) -> Bool {
    // Focus the field first
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
    usleep(100_000)

    // Try setting value via AX directly
    let axResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
    if axResult == .success {
        // Verify
        let newValue = getAttr(element, kAXValueAttribute) ?? ""
        if newValue == value { return true }
    }

    // Fallback: select all + type
    KeyboardController.pressCombo("cmd+a")
    usleep(80_000)
    KeyboardController.typeText(value)
    usleep(200_000)

    let newValue = getAttr(element, kAXValueAttribute) ?? ""
    return newValue.contains(value) || !newValue.isEmpty
}

// MARK: - App Element Helpers

private func frontmostAppElement() -> AXUIElement? {
    guard let pid = findAppPID(nil) else { return nil }
    return AXUIElementCreateApplication(pid)
}

/// Find the app that currently has a modal dialog open (sheet/dialog).
/// This is more reliable than frontmostApp when running from a terminal.
private func findAppWithDialog() -> AXUIElement? {
    // First try frontmost app
    if let frontmost = NSWorkspace.shared.frontmostApplication {
        let element = AXUIElementCreateApplication(frontmost.processIdentifier)
        if hasDialog(element) { return element }
    }

    // If frontmost doesn't have a dialog, scan recent/visible apps
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if hasDialog(element) { return element }
    }

    // Fallback to frontmost
    return frontmostAppElement()
}

/// Find the NSRunningApplication that owns a dialog and activate it.
/// This ensures keyboard events reach the dialog, not the terminal.
@discardableResult
private func activateAppWithDialog() -> NSRunningApplication? {
    // Check frontmost first
    if let frontmost = NSWorkspace.shared.frontmostApplication {
        let element = AXUIElementCreateApplication(frontmost.processIdentifier)
        if hasDialog(element) { return frontmost }
    }

    // Find and activate the app with a dialog
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if hasDialog(element) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            usleep(300_000) // wait for activation
            return app
        }
    }
    return nil
}

/// Check if an app element has any open dialog/sheet
private func hasDialog(_ appElement: AXUIElement) -> Bool {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return false }

    for window in windows {
        if hasDialogChild(window, depth: 0) { return true }
    }
    return false
}

private func hasDialogChild(_ element: AXUIElement, depth: Int) -> Bool {
    guard depth < 5 else { return false }
    let role = getAttr(element, kAXRoleAttribute) ?? ""
    if role == "AXSheet" || role == "AXDialog" { return true }
    guard let children = getChildren(element) else { return false }
    for child in children {
        if hasDialogChild(child, depth: depth + 1) { return true }
    }
    return false
}

private func waitForDialogElement(label: String, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let appElement = frontmostAppElement(), findElement(appElement, matching: label, depth: 12) != nil {
            return true
        }
        usleep(150_000)
    }
    return false
}

// MARK: - Legacy helper (used by file-open, file-save)
private func openGoToFolderSheet(path: String) {
    KeyboardController.pressCombo("cmd+shift+g")
    usleep(300_000)
    KeyboardController.typeText(path)
    usleep(120_000)
    KeyboardController.pressCombo("return")
}

// MARK: - Commands

struct Dialog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File dialog interaction framework",
        subcommands: [
            DialogDetect.self,
            DialogInspect.self,
            DialogDismiss.self,
            DialogAutoDismiss.self,
            DialogNavigate.self,
            DialogSelect.self,
            DialogListFiles.self,
            DialogSetField.self,
            DialogClickButton.self,
            DialogFileOpen.self,
            DialogFileSave.self,
        ]
    )
}

// MARK: - dialog inspect (NEW: Full AX introspection)

struct DialogInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect all interactive elements in the current dialog"
    )

    @Option(name: .long, help: "Max AX tree depth to scan") var depth: Int = 15
    @Flag(name: .long) var json = false

    func run() throws {
        guard let appElement = findAppWithDialog() else {
            JSONOutput.error("No app with dialog found", json: json)
            throw ExitCode.failure
        }

        let elements = scanDialogElements(appElement, maxDepth: depth)

        // Separate into categories for easier consumption
        let textFields = elements.filter { r in
            let role = r["role"] as? String ?? ""
            return role == "AXTextField" || role == "AXComboBox" || role == "AXTextArea"
        }
        let buttons = elements.filter { ($0["role"] as? String ?? "").contains("Button") }
        let sheets = elements.filter { ($0["role"] as? String ?? "") == "AXSheet" }

        let focusedField = textFields.first(where: { $0["focused"] as? Bool == true })

        var result: [String: Any] = [
            "status": "ok",
            "elementCount": elements.count,
            "textFields": textFields,
            "buttons": buttons,
            "sheets": sheets,
        ]
        if let ff = focusedField {
            result["focusedField"] = ff
        }
        result["message"] = "Found \(elements.count) elements: \(textFields.count) text fields, \(buttons.count) buttons"

        JSONOutput.print(result, json: json)
    }
}

// MARK: - dialog detect

struct DialogDetect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "detect", abstract: "Detect modal dialog in the frontmost app")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let dialog = detectFrontmostModalDialog() else {
            JSONOutput.print([
                "status": "ok",
                "hasDialog": false,
                "message": "No modal dialog detected",
            ], json: json)
            return
        }

        var payload: [String: Any] = [
            "status": "ok",
            "hasDialog": true,
            "title": dialog.title,
            "buttons": dialog.buttons,
            "role": dialog.role,
            "modal": dialog.isModal,
            "message": dialog.title.isEmpty ? "Modal dialog detected" : "Modal dialog detected: \(dialog.title)",
        ]
        payload["dialog"] = modalDialogPayload(dialog)
        JSONOutput.print(payload, json: json)
    }
}

// MARK: - dialog dismiss / auto-dismiss

struct DialogDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss current modal dialog by button name")

    @Argument(help: "Button label to click, for example \"Don't Save\"") var buttonName: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog dismissal")

        guard let dialog = findFrontmostModalDialogMatch() else {
            JSONOutput.error("No modal dialog detected", json: json)
            throw ExitCode.failure
        }

        guard let button = findDialogButton(named: buttonName, in: dialog.buttons) else {
            let available = dialog.info.buttons.joined(separator: ", ")
            JSONOutput.error(
                available.isEmpty
                    ? "Dialog has no accessible buttons"
                    : "Button '\(buttonName)' not found. Available: \(available)",
                json: json
            )
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        let actionResult = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
        guard actionResult == .success else {
            JSONOutput.error("Failed to press '\(button.title)' (AX error: \(actionResult.rawValue))", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Pressed '\(button.title)'",
            "button": button.title,
            "dialog": modalDialogPayload(dialog.info),
        ], json: json)
    }
}

struct DialogAutoDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto-dismiss", abstract: "Auto-dismiss current modal dialog using safe defaults")

    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog auto-dismiss")

        guard let dialog = findFrontmostModalDialogMatch() else {
            JSONOutput.print([
                "status": "ok",
                "hasDialog": false,
                "message": "No modal dialog detected",
            ], json: json)
            return
        }

        guard let selectedButton = preferredAutoDismissButton(in: dialog.buttons) else {
            let available = dialog.info.buttons.joined(separator: ", ")
            JSONOutput.error(
                available.isEmpty
                    ? "Dialog has no accessible buttons"
                    : "No preferred dismiss button found. Available: \(available)",
                json: json
            )
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        let actionResult = AXUIElementPerformAction(selectedButton.element, kAXPressAction as CFString)
        guard actionResult == .success else {
            JSONOutput.error("Failed to press '\(selectedButton.title)' (AX error: \(actionResult.rawValue))", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Auto-dismissed dialog with '\(selectedButton.title)'",
            "button": selectedButton.title,
            "dialog": modalDialogPayload(dialog.info),
        ], json: json)
    }
}

// MARK: - dialog navigate (AX-aware: wait for focus, verify, report)

struct DialogNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Navigate to path in open/save dialog"
    )

    @Argument(help: "Path to navigate to") var path: String
    @Option(name: .long, help: "Wait timeout in seconds") var timeout: Double = 3.0
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog navigation")
        flashIndicatorIfRunning()

        // Find and activate the app that owns the dialog
        // This ensures keyboard events reach the dialog, not the terminal
        guard let dialogOwner = activateAppWithDialog() else {
            JSONOutput.error("No app with open dialog found", json: json)
            throw ExitCode.failure
        }
        let dialogApp = AXUIElementCreateApplication(dialogOwner.processIdentifier)

        // Step 1: Open the "Go to the folder" sheet
        KeyboardController.pressCombo("cmd+shift+g")

        // Step 2: Wait for a text input to appear (poll the dialog-owning app)
        let deadline = Date().addingTimeInterval(timeout)
        var textField: AXUIElement?

        while Date() < deadline {
            usleep(150_000)
            let app = findAppWithDialog() ?? dialogApp
            // Try focused field first, then any ComboBox (Go To path entry)
            textField = findFocusedTextInput(in: app)
            if textField != nil { break }
            textField = findDialogField(app, role: "AXComboBox")
            if textField != nil { break }
        }

        guard let field = textField else {
            let app = findAppWithDialog() ?? dialogApp
            let elements = scanDialogElements(app, maxDepth: 10)
            let fields = elements.filter { r in
                let role = r["role"] as? String ?? ""
                return role.contains("TextField") || role.contains("ComboBox")
            }
            JSONOutput.error(
                "Go To sheet did not appear (no text field found after \(timeout)s). " +
                "Found \(fields.count) text fields. Use 'dialog inspect --json' to debug.",
                json: json
            )
            throw ExitCode.failure
        }

        // Step 3: Set the path value via AX (direct, no keyboard events needed)
        let resolvedPath = NSString(string: path).expandingTildeInPath
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)
        usleep(100_000)

        // Try AX value set first (most reliable — bypasses keyboard entirely)
        let axResult = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, resolvedPath as CFTypeRef
        )
        if axResult != .success {
            // Fallback: re-activate app and use keyboard
            dialogOwner.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            usleep(200_000)
            KeyboardController.pressCombo("cmd+a")
            usleep(80_000)
            KeyboardController.typeText(resolvedPath)
        }
        usleep(400_000)

        // Step 4: Re-activate app and press Return to confirm
        dialogOwner.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        usleep(200_000)
        KeyboardController.pressCombo("return")
        usleep(800_000)

        // Step 5: Verify — read the current path from the dialog
        let app = findAppWithDialog() ?? dialogApp
        let verifiedPath = readCurrentPath(in: app)
        let navigated = verifiedPath?.contains(
            URL(fileURLWithPath: path).lastPathComponent
        ) == true

        var result: [String: Any] = [
            "status": "ok",
            "message": navigated ? "Navigated to \(path)" : "Attempted navigation to \(path)",
            "path": path,
            "verified": navigated,
        ]
        if let vp = verifiedPath { result["currentPath"] = vp }

        JSONOutput.print(result, json: json)
    }
}

/// Find a currently focused text input (AXTextField or AXComboBox, not search field)
private func findFocusedTextInput(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 15 else { return nil }
    let role = getAttr(root, kAXRoleAttribute) ?? ""
    let subrole = getAttr(root, kAXSubroleAttribute) ?? ""
    let focused = getBoolAttr(root, kAXFocusedAttribute) ?? false

    if focused && (role == "AXTextField" || role == "AXComboBox") && subrole != "AXSearchField" {
        return root
    }

    guard let children = getChildren(root) else { return nil }
    for child in children {
        if let found = findFocusedTextInput(in: child, depth: depth + 1) { return found }
    }
    return nil
}

/// Read the current folder path from any text value in the dialog
private func readCurrentPath(in root: AXUIElement, depth: Int = 0) -> String? {
    guard depth < 12 else { return nil }
    let value = getAttr(root, kAXValueAttribute) ?? ""
    let title = getAttr(root, kAXTitleAttribute) ?? ""

    if value.hasPrefix("/") && !value.contains("\n") && value.count < 500 { return value }
    if title.hasPrefix("/") && !title.contains("\n") && title.count < 500 { return title }

    guard let children = getChildren(root) else { return nil }
    for child in children {
        if let path = readCurrentPath(in: child, depth: depth + 1) { return path }
    }
    return nil
}

// MARK: - dialog select (IMPROVED: no auto-confirm by default)

struct DialogSelect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select a file in the dialog"
    )

    @Argument(help: "Filename to select") var filename: String
    @Flag(name: .long, help: "Auto-confirm (press Return) after selecting") var confirm = false
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog selection")
        flashIndicatorIfRunning()

        guard let pid = findAppPID(nil) else {
            JSONOutput.error("No frontmost app", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        // Try to find the file in the AX tree
        var found = false
        if let element = findElement(appElement, matching: filename, depth: 12) {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            usleep(200_000)
            found = true
        } else {
            // Try typing the filename to filter/select
            KeyboardController.typeText(filename)
            usleep(300_000)
        }

        if confirm {
            KeyboardController.pressCombo("return")
            usleep(200_000)
        }

        JSONOutput.print([
            "status": "ok",
            "message": found
                ? (confirm ? "Selected and confirmed \(filename)" : "Selected \(filename)")
                : (confirm ? "Typed and confirmed \(filename)" : "Typed \(filename) (use --confirm to press Return)"),
            "filename": filename,
            "foundInTree": found,
            "confirmed": confirm,
        ], json: json)
    }
}

// MARK: - dialog list-files (NEW: list visible files in dialog)

struct DialogListFiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-files",
        abstract: "List files currently visible in the file dialog"
    )

    @Flag(name: .long) var json = false

    func run() throws {
        guard let appElement = findAppWithDialog() else {
            JSONOutput.error("No app with dialog found", json: json)
            throw ExitCode.failure
        }

        let items = collectDialogFileItems(appElement)

        // Deduplicate by name
        var seen = Set<String>()
        let unique = items.filter { item in
            let name = item["name"] as? String ?? ""
            guard !name.isEmpty, !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }

        JSONOutput.print([
            "status": "ok",
            "files": unique,
            "count": unique.count,
            "message": "Found \(unique.count) items in dialog",
        ], json: json)
    }
}

// MARK: - dialog set-field (NEW: set any text field value)

struct DialogSetField: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-field",
        abstract: "Set a text field value in the current dialog"
    )

    @Argument(help: "Value to set") var value: String
    @Option(name: .long, help: "Match field by role (e.g. AXComboBox, AXTextField)") var role: String?
    @Option(name: .long, help: "Match field by label/description") var label: String?
    @Flag(name: .long, help: "Set the currently focused field") var focused = false
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog field set")
        flashIndicatorIfRunning()

        guard let appElement = findAppWithDialog() else {
            JSONOutput.error("No app with dialog found", json: json)
            throw ExitCode.failure
        }

        var targetField: AXUIElement?

        if focused {
            // Find the currently focused text field
            targetField = findFocusedField(in: appElement)
        } else {
            targetField = findDialogField(appElement, role: role, label: label)
        }

        guard let field = targetField else {
            let allFields = scanDialogElements(appElement, maxDepth: 12).filter { r in
                let role = r["role"] as? String ?? ""
                return role.contains("TextField") || role.contains("ComboBox") || role.contains("TextArea")
            }

            JSONOutput.error(
                "No matching text field found. Dialog has \(allFields.count) text fields. " +
                "Use 'dialog inspect --json' to see all fields.",
                json: json
            )
            throw ExitCode.failure
        }

        let success = setFieldValue(field, value: value)
        let readBack = getAttr(field, kAXValueAttribute) ?? ""

        JSONOutput.print([
            "status": success ? "ok" : "error",
            "message": success ? "Set field value to '\(value)'" : "Failed to set field value",
            "value": value,
            "readBack": readBack,
            "fieldRole": getAttr(field, kAXRoleAttribute) ?? "",
        ], json: json)
    }

    private func findFocusedField(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 15 else { return nil }
        let role = getAttr(root, kAXRoleAttribute) ?? ""
        let focused = getBoolAttr(root, kAXFocusedAttribute) ?? false

        if focused && (role == "AXTextField" || role == "AXComboBox" || role == "AXTextArea") {
            return root
        }

        guard let children = getChildren(root) else { return nil }
        for child in children {
            if let found = findFocusedField(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

// MARK: - dialog click-button (NEW: click any button by label)

struct DialogClickButton: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click-button",
        abstract: "Click a button in the current dialog by label"
    )

    @Argument(help: "Button label to click") var label: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog button click")
        flashIndicatorIfRunning()

        guard let appElement = findAppWithDialog() else {
            JSONOutput.error("No app with dialog found", json: json)
            throw ExitCode.failure
        }

        guard let button = findDialogButtonElement(appElement, label: label) else {
            // List available buttons for helpful error
            let allButtons = scanDialogElements(appElement, maxDepth: 12).filter {
                ($0["role"] as? String ?? "").contains("Button")
            }.compactMap { $0["title"] as? String }.filter { !$0.isEmpty }

            JSONOutput.error(
                allButtons.isEmpty
                    ? "No button '\(label)' found in dialog"
                    : "Button '\(label)' not found. Available: \(allButtons.joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            JSONOutput.error("Failed to click '\(label)' (AX error: \(result.rawValue))", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Clicked '\(label)'",
            "button": label,
        ], json: json)
    }
}

// MARK: - dialog file-open / file-save (use improved navigate internally)

struct DialogFileOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "file-open", abstract: "Open a file via native open dialog")

    @Argument(help: "File path to open") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "file open dialog")

        let fullPath = URL(fileURLWithPath: path).standardized.path
        guard FileManager.default.fileExists(atPath: fullPath) else {
            JSONOutput.error("File not found: \(fullPath)", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        KeyboardController.pressCombo("cmd+o")

        guard waitForDialogElement(label: "Open", timeout: 3.0) || waitForDialogElement(label: "Choose", timeout: 1.5) else {
            JSONOutput.error("Open dialog did not appear", json: json)
            throw ExitCode.failure
        }

        openGoToFolderSheet(path: fullPath)
        usleep(200_000)
        KeyboardController.pressCombo("return")

        JSONOutput.print([
            "status": "ok",
            "message": "Requested open for \(fullPath)",
            "path": fullPath,
        ], json: json)
    }
}

struct DialogFileSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "file-save", abstract: "Save a file via native save dialog")

    @Argument(help: "Destination file path") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "file save dialog")

        let resolvedPath = URL(fileURLWithPath: path).standardized.path
        let url = URL(fileURLWithPath: resolvedPath)
        let directory = url.deletingLastPathComponent().path
        let filename = url.lastPathComponent

        guard !filename.isEmpty else {
            JSONOutput.error("Invalid destination path", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        KeyboardController.pressCombo("cmd+shift+s")
        guard waitForDialogElement(label: "Save", timeout: 3.0) else {
            JSONOutput.error("Save dialog did not appear", json: json)
            throw ExitCode.failure
        }

        if !directory.isEmpty {
            openGoToFolderSheet(path: directory)
            usleep(250_000)
        }

        KeyboardController.pressCombo("cmd+a")
        usleep(80_000)
        KeyboardController.typeText(filename)
        usleep(100_000)
        KeyboardController.pressCombo("return")

        JSONOutput.print([
            "status": "ok",
            "message": "Requested save to \(resolvedPath)",
            "path": resolvedPath,
        ], json: json)
    }
}
