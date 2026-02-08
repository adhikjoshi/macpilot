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

    @Argument(help: "App name") var name: String
    @Flag(name: .long) var json = false

    func run() throws {
        let config = NSWorkspace.OpenConfiguration()
        let semaphore = DispatchSemaphore(value: 0)
        var openError: Error?

        // Try to find by name in /Applications
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? findAppURL(name)

        guard let appURL = url else {
            JSONOutput.error("App not found: \(name)", json: json)
            throw ExitCode.failure
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            openError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = openError {
            JSONOutput.error("Failed to open \(name): \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }
        JSONOutput.print(["status": "ok", "message": "Opened \(name)"], json: json)
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
        // Safety check
        if let reason = Safety.validateQuit(appName: name) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) else {
            JSONOutput.error("App not running: \(name)", json: json)
            throw ExitCode.failure
        }

        // Double-check with resolved name
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
    let paths = ["/Applications", "/System/Applications", "/Applications/Utilities"]
    for path in paths {
        let appPath = "\(path)/\(name).app"
        if FileManager.default.fileExists(atPath: appPath) {
            return URL(fileURLWithPath: appPath)
        }
    }
    // Try LSCopyApplicationURLsForURL or spotlight
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = ["kMDItemKind == 'Application' && kMDItemDisplayName == '\(name)'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8),
       let firstLine = output.components(separatedBy: "\n").first,
       !firstLine.isEmpty {
        return URL(fileURLWithPath: firstLine)
    }
    return nil
}
