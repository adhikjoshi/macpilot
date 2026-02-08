import ArgumentParser
import Foundation

@main
struct MacPilot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macpilot",
        abstract: "Programmatic macOS control for AI agents",
        version: "0.3.0",
        subcommands: [
            Click.self,
            DoubleClick.self,
            RightClick.self,
            Move.self,
            Drag.self,
            Scroll.self,
            TypeText.self,
            Key.self,
            Screenshot.self,
            UI.self,
            App.self,
            Clipboard.self,
            Window.self,
            Dialog.self,
            Shell.self,
            Wait.self,
            Space.self,
            AXCheck.self,
            Chain.self,
            Chrome.self,
            Run.self,
        ]
    )
}

// MARK: - JSON Output Helper

struct JSONOutput {
    static func print(_ dict: [String: Any], json: Bool) {
        if json {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                Swift.print(str)
            }
        } else {
            if let msg = dict["message"] as? String {
                Swift.print(msg)
            } else if let status = dict["status"] as? String {
                Swift.print(status)
            }
        }
    }

    static func printArray(_ arr: [[String: Any]], json: Bool) {
        if json {
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                Swift.print(str)
            }
        }
    }

    static func error(_ message: String, json: Bool) {
        let dict: [String: Any] = ["error": message, "status": "error"]
        if json {
            print(dict, json: true)
        } else {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        }
    }
}
