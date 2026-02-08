import ArgumentParser
import Foundation

private enum ChainAction {
    case key(String)
    case type(String)
    case sleep(UInt32)

    var needsKeyboardInput: Bool {
        switch self {
        case .key, .type: return true
        case .sleep: return false
        }
    }
}

struct Chain: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chain", abstract: "Execute multiple keyboard actions in sequence")

    @Argument(help: "Actions, inline JSON, or JSON file path")
    var actions: [String]

    @Option(name: .long, help: "Delay between actions in milliseconds (default 200)")
    var delay: UInt32 = 200

    @Flag(name: .long) var json = false

    func run() throws {
        let parsedActions = try resolveActions()
        guard !parsedActions.isEmpty else {
            JSONOutput.error("No actions provided", json: json)
            throw ExitCode.failure
        }

        if parsedActions.contains(where: { $0.needsKeyboardInput }) {
            try requireActiveUserSession(json: json, actionDescription: "chain keyboard actions")
        }

        var results: [[String: Any]] = []

        for (i, action) in parsedActions.enumerated() {
            if i > 0 {
                usleep(delay * 1000)
            }

            switch action {
            case .type(let text):
                KeyboardController.typeText(text)
                results.append(["action": "type", "text": text, "status": "ok"])
            case .sleep(let ms):
                usleep(ms * 1000)
                results.append(["action": "sleep", "ms": Int(ms), "status": "ok"])
            case .key(let combo):
                KeyboardController.pressCombo(combo)
                results.append(["action": "key", "combo": combo, "status": "ok"])
            }
        }

        flashIndicatorIfRunning()

        if json {
            JSONOutput.print(["status": "ok", "message": "Executed \(parsedActions.count) actions", "actions": results], json: true)
        } else {
            print("Executed \(parsedActions.count) actions")
        }
    }

    private func resolveActions() throws -> [ChainAction] {
        if actions.count == 1 {
            let only = actions[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if isLikelyJSON(only) {
                return try parseStructuredActions(from: only)
            }

            if FileManager.default.fileExists(atPath: only) {
                let content = try String(contentsOfFile: only, encoding: .utf8)
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if isLikelyJSON(trimmed) {
                    return try parseStructuredActions(from: trimmed)
                }
                return try parseLegacyActions(fromMultilineContent: content)
            }

            if only.contains("\n") {
                if isLikelyJSON(only) {
                    return try parseStructuredActions(from: only)
                }
                return try parseLegacyActions(fromMultilineContent: only)
            }
        }

        return try actions.map(parseLegacyAction)
    }

    private func parseStructuredActions(from jsonString: String) throws -> [ChainAction] {
        guard let data = jsonString.data(using: .utf8) else {
            throw ValidationError("Invalid UTF-8 in chain actions")
        }

        let raw = try JSONSerialization.jsonObject(with: data)
        if let arr = raw as? [Any] {
            return try arr.map(parseJSONAction)
        }
        if let obj = raw as? [String: Any], let arr = obj["actions"] as? [Any] {
            return try arr.map(parseJSONAction)
        }
        throw ValidationError("JSON chain input must be an array or an object with an 'actions' array")
    }

    private func parseJSONAction(_ value: Any) throws -> ChainAction {
        if let str = value as? String {
            return try parseLegacyAction(str)
        }

        guard let obj = value as? [String: Any] else {
            throw ValidationError("Unsupported chain action entry")
        }

        if let ms = obj["sleep"] as? NSNumber {
            return .sleep(UInt32(truncating: ms))
        }

        let type = (obj["type"] as? String ?? "").lowercased()
        switch type {
        case "type", "text":
            guard let text = obj["value"] as? String ?? obj["text"] as? String else {
                throw ValidationError("type action requires 'value' or 'text'")
            }
            return .type(text)
        case "key", "combo", "shortcut":
            guard let combo = obj["value"] as? String ?? obj["combo"] as? String else {
                throw ValidationError("key action requires 'value' or 'combo'")
            }
            return .key(combo)
        case "sleep":
            if let ms = obj["ms"] as? NSNumber {
                return .sleep(UInt32(truncating: ms))
            }
            if let ms = obj["value"] as? NSNumber {
                return .sleep(UInt32(truncating: ms))
            }
            throw ValidationError("sleep action requires numeric 'ms' or 'value'")
        default:
            throw ValidationError("Unsupported chain action type: \(type)")
        }
    }

    private func parseLegacyActions(fromMultilineContent content: String) throws -> [ChainAction] {
        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parsed: [ChainAction] = []

        for line in rawLines {
            var token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if token == "[" || token == "]" { continue }
            if token.hasSuffix(",") { token.removeLast() }
            token = stripWrappedQuotes(token)
            if token.isEmpty { continue }
            parsed.append(try parseLegacyAction(token))
        }

        return parsed
    }

    private func parseLegacyAction(_ raw: String) throws -> ChainAction {
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { throw ValidationError("Empty chain action") }

        if action.hasPrefix("type:") {
            return .type(String(action.dropFirst(5)))
        }
        if action.hasPrefix("sleep:") {
            guard let ms = UInt32(action.dropFirst(6)) else {
                throw ValidationError("Invalid sleep action: \(action)")
            }
            return .sleep(ms)
        }
        return .key(action)
    }

    private func stripWrappedQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func isLikelyJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
    }
}
