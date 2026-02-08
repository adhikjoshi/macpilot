import ArgumentParser
import AppKit
import Foundation

private func frontmostAppElement() -> AXUIElement? {
    guard let pid = findAppPID(nil) else { return nil }
    return AXUIElementCreateApplication(pid)
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

private func openGoToFolderSheet(path: String) {
    KeyboardController.pressCombo("cmd+shift+g")
    usleep(300_000)
    KeyboardController.typeText(path)
    usleep(120_000)
    KeyboardController.pressCombo("return")
}

struct Dialog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File dialog navigation",
        subcommands: [
            DialogDetect.self,
            DialogDismiss.self,
            DialogAutoDismiss.self,
            DialogNavigate.self,
            DialogSelect.self,
            DialogFileOpen.self,
            DialogFileSave.self,
        ]
    )
}

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

struct DialogNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "navigate", abstract: "Navigate to path in open/save dialog")

    @Argument(help: "Path to navigate to") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog navigation")
        flashIndicatorIfRunning()

        openGoToFolderSheet(path: path)
        usleep(500_000)

        JSONOutput.print(["status": "ok", "message": "Navigated to \(path)"], json: json)
    }
}

struct DialogSelect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "select", abstract: "Select a file in the dialog")

    @Argument(help: "Filename to select") var filename: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "dialog selection")
        flashIndicatorIfRunning()

        // Use the frontmost app's accessibility to find and click the file.
        guard let pid = findAppPID(nil) else {
            JSONOutput.error("No frontmost app", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        if let element = findElement(appElement, matching: filename, depth: 10) {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            usleep(200_000)
            KeyboardController.pressCombo("return")
            JSONOutput.print(["status": "ok", "message": "Selected \(filename)"], json: json)
        } else {
            KeyboardController.typeText(filename)
            usleep(200_000)
            KeyboardController.pressCombo("return")
            JSONOutput.print(["status": "ok", "message": "Typed and confirmed \(filename)"], json: json)
        }
    }
}

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
