import ArgumentParser
import AppKit
import Foundation

struct App: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "App management",
        subcommands: [AppOpen.self, AppFocus.self, AppList.self, AppQuit.self]
    )
}

struct AppOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open an application")

    @Argument(help: "App name or bundle identifier") var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        let config = NSWorkspace.OpenConfiguration()
        let semaphore = DispatchSemaphore(value: 0)
        var openError: Error?

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeBundleID = trimmed.contains(".") && !trimmed.contains("/") && !trimmed.contains(" ")

        var attempts: [String] = []
        var appURL: URL?

        if looksLikeBundleID {
            attempts.append("bundle-id lookup")
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
        }

        if appURL == nil {
            attempts.append("name lookup")
            appURL = findAppURL(trimmed)
        }

        guard let url = appURL else {
            JSONOutput.error(
                "App not found: \(name). Tried: \(attempts.joined(separator: ", "))",
                json: json
            )
            throw ExitCode.failure
        }

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            openError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = openError {
            JSONOutput.error("Failed to open \(name): \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Opened \(name)",
            "appPath": url.path,
        ], json: json)
    }
}

struct AppFocus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus", abstract: "Focus/activate an app")

    @Argument var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) else {
            JSONOutput.error("App not running: \(name)", json: json)
            throw ExitCode.failure
        }
        app.activate()
        JSONOutput.print(["status": "ok", "message": "Focused \(app.localizedName ?? name)"], json: json)
    }
}

struct AppList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List running apps")

    @Flag(name: .long) var json = false

    func run() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let name = app.localizedName else { return nil }
                return [
                    "name": name,
                    "pid": app.processIdentifier,
                    "bundleId": app.bundleIdentifier ?? "",
                    "active": app.isActive,
                ]
            }

        if json {
            JSONOutput.printArray(apps, json: true)
        } else {
            for app in apps {
                let name = app["name"] as? String ?? ""
                let pid = app["pid"] as? pid_t ?? 0
                let active = (app["active"] as? Bool == true) ? " *" : ""
                print("\(name) (pid: \(pid))\(active)")
            }
        }
    }
}

struct AppQuit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit an app")

    @Argument var name: String
    @Flag(name: .long, help: "Force quit") var force = false
    @Flag(name: .long) var json = false

    func run() throws {
        if let reason = Safety.validateQuit(appName: name) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) else {
            JSONOutput.error("App not running: \(name)", json: json)
            throw ExitCode.failure
        }

        if let resolvedName = app.localizedName, let reason = Safety.validateQuit(appName: resolvedName) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
        JSONOutput.print(["status": "ok", "message": "Quit \(app.localizedName ?? name)"], json: json)
    }
}

func findAppURL(_ name: String) -> URL? {
    if name.hasSuffix(".app"), FileManager.default.fileExists(atPath: name) {
        return URL(fileURLWithPath: name)
    }

    if let appByName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
        return appByName
    }

    if let appByNamePath = NSWorkspace.shared.fullPath(forApplication: name) {
        return URL(fileURLWithPath: appByNamePath)
    }

    let cleanName = name.replacingOccurrences(of: ".app", with: "")
    let paths = ["/Applications", "/System/Applications", "/Applications/Utilities"]
    for path in paths {
        let appPath = "\(path)/\(cleanName).app"
        if FileManager.default.fileExists(atPath: appPath) {
            return URL(fileURLWithPath: appPath)
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(cleanName)'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8),
       let firstLine = output.split(separator: "\n").first {
        let result = String(firstLine)
        if !result.isEmpty {
            return URL(fileURLWithPath: result)
        }
    }

    return nil
}
