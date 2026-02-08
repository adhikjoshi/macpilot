import ArgumentParser
import Foundation

struct Chain: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chain", abstract: "Execute multiple keyboard actions in sequence")

    @Argument(help: "Actions: key combos (e.g. cmd+l), type:text, or sleep:ms")
    var actions: [String]

    @Option(name: .long, help: "Delay between actions in milliseconds (default 200)")
    var delay: UInt32 = 200

    @Flag(name: .long) var json = false

    func run() {
        var results: [[String: Any]] = []

        for (i, action) in actions.enumerated() {
            if i > 0 {
                usleep(delay * 1000)
            }

            if action.hasPrefix("type:") {
                let text = String(action.dropFirst(5))
                KeyboardController.typeText(text)
                results.append(["action": "type", "text": text, "status": "ok"])
            } else if action.hasPrefix("sleep:") {
                if let ms = UInt32(action.dropFirst(6)) {
                    usleep(ms * 1000)
                    results.append(["action": "sleep", "ms": Int(ms), "status": "ok"])
                }
            } else {
                // Treat as key combo
                KeyboardController.pressCombo(action)
                results.append(["action": "key", "combo": action, "status": "ok"])
            }
        }

        if json {
            JSONOutput.print(["status": "ok", "message": "Executed \(actions.count) actions", "actions": results], json: true)
        } else {
            print("Executed \(actions.count) actions")
        }
    }
}
