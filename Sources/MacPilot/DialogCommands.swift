import ArgumentParser
import AppKit
import Foundation

struct Dialog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File dialog navigation",
        subcommands: [DialogNavigate.self, DialogSelect.self]
    )
}

struct DialogNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "navigate", abstract: "Navigate to path in open/save dialog")

    @Argument(help: "Path to navigate to") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        // Press Cmd+Shift+G to open "Go to folder" sheet
        KeyboardController.pressCombo("cmd+shift+g")
        usleep(500_000) // Wait 500ms for sheet to appear

        // Type the path
        KeyboardController.typeText(path)
        usleep(200_000)

        // Press Enter to navigate
        KeyboardController.pressCombo("return")
        usleep(500_000)

        JSONOutput.print(["status": "ok", "message": "Navigated to \(path)"], json: json)
    }
}

struct DialogSelect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "select", abstract: "Select a file in the dialog")

    @Argument(help: "Filename to select") var filename: String
    @Flag(name: .long) var json = false

    func run() throws {
        // Use the frontmost app's accessibility to find and click the file
        guard let pid = findAppPID(nil) else {
            JSONOutput.error("No frontmost app", json: json)
            throw ExitCode.failure
        }
        let appElement = AXUIElementCreateApplication(pid)

        // Try to find the element matching filename
        if let element = findElement(appElement, matching: filename, depth: 10) {
            // Click it (select)
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            usleep(200_000)
            // Double-click or press Open — press Enter to confirm
            KeyboardController.pressCombo("return")
            JSONOutput.print(["status": "ok", "message": "Selected \(filename)"], json: json)
        } else {
            // Fallback: type filename and press Enter
            KeyboardController.typeText(filename)
            usleep(200_000)
            KeyboardController.pressCombo("return")
            JSONOutput.print(["status": "ok", "message": "Typed and confirmed \(filename)"], json: json)
        }
    }
}
