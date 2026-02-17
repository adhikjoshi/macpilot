import ArgumentParser
import Foundation

// MARK: - Gap V: Login items listing

struct LoginItems: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-items",
        abstract: "List login items (launch agents and daemons)"
    )

    @Flag(name: .long) var json = false

    func run() throws {
        var items: [[String: Any]] = []

        // User launch agents
        let userAgentsPath = NSHomeDirectory() + "/Library/LaunchAgents"
        items.append(contentsOf: scanLaunchDir(userAgentsPath, scope: "user-agent"))

        // System launch agents
        items.append(contentsOf: scanLaunchDir("/Library/LaunchAgents", scope: "system-agent"))

        // System launch daemons
        items.append(contentsOf: scanLaunchDir("/Library/LaunchDaemons", scope: "system-daemon"))

        if json {
            JSONOutput.print([
                "status": "ok",
                "count": items.count,
                "items": items,
            ], json: true)
        } else {
            if items.isEmpty {
                print("No login items found")
            } else {
                for item in items {
                    let label = item["label"] as? String ?? ""
                    let scope = item["scope"] as? String ?? ""
                    let enabled = (item["enabled"] as? Bool ?? true) ? "" : " [disabled]"
                    print("[\(scope)] \(label)\(enabled)")
                }
            }
        }
    }

    private func scanLaunchDir(_ path: String, scope: String) -> [[String: Any]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        return files.filter { $0.hasSuffix(".plist") }.compactMap { file in
            let fullPath = "\(path)/\(file)"
            guard let data = fm.contents(atPath: fullPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }

            let label = plist["Label"] as? String ?? file.replacingOccurrences(of: ".plist", with: "")
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
            let disabled = plist["Disabled"] as? Bool ?? false

            var info: [String: Any] = [
                "label": label,
                "scope": scope,
                "path": fullPath,
                "enabled": !disabled,
            ]
            if !program.isEmpty { info["program"] = program }
            if let runAtLoad = plist["RunAtLoad"] as? Bool { info["runAtLoad"] = runAtLoad }

            return info
        }
    }
}
