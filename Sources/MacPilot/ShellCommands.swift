import ArgumentParser
import AppKit
import Foundation

struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shell/terminal commands",
        subcommands: [ShellRun.self, ShellInteractive.self, ShellType.self, ShellPaste.self]
    )
}

struct ShellRun: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run command and return output")

    @Argument(help: "Command to run") var command: String
    @Flag(name: .long) var json = false

    func run() throws {
        // Safety check
        if let reason = Safety.validateShellCommand(command) {
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        try task.run()
        task.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let code = Int(task.terminationStatus)

        if json {
            JSONOutput.print([
                "status": code == 0 ? "ok" : "error",
                "exitCode": code,
                "stdout": stdout,
                "stderr": stderr,
            ], json: true)
        } else {
            if !stdout.isEmpty { print(stdout, terminator: "") }
            if !stderr.isEmpty { FileHandle.standardError.write(Data(stderr.utf8)) }
        }
        if code != 0 {
            throw ExitCode(Int32(code))
        }
    }
}

struct ShellInteractive: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "interactive", abstract: "Open Terminal and run command")

    @Argument(help: "Command to run") var command: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "interactive Terminal automation")

        // Open Terminal.app
        let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            JSONOutput.error("Failed to open Terminal interactive session", json: json)
            throw ExitCode.failure
        }

        // Activate Terminal
        let activateScript = "tell application \"Terminal\" to activate"
        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task2.arguments = ["-e", activateScript]
        try task2.run()
        task2.waitUntilExit()
        if task2.terminationStatus != 0 {
            JSONOutput.error("Failed to activate Terminal", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print(["status": "ok", "message": "Opened Terminal with command"], json: json)
    }
}

struct ShellType: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into active terminal")

    @Argument(help: "Text to type") var text: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "terminal typing")

        // Focus Terminal
        let apps = NSWorkspace.shared.runningApplications
        if let terminal = apps.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
            terminal.activate()
            usleep(300_000)
        }
        KeyboardController.typeText(text)
        JSONOutput.print(["status": "ok", "message": "Typed \(text.count) chars into terminal"], json: json)
    }
}

struct ShellPaste: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "paste", abstract: "Paste text into active terminal via clipboard")

    @Argument(help: "Text to paste") var text: String
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "terminal paste")

        // Save current clipboard
        let pb = NSPasteboard.general
        let oldText = pb.string(forType: .string)

        // Set clipboard
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Focus Terminal
        let apps = NSWorkspace.shared.runningApplications
        if let terminal = apps.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
            terminal.activate()
            usleep(300_000)
        }

        // Paste
        KeyboardController.pressCombo("cmd+v")
        usleep(100_000)

        // Restore clipboard
        if let old = oldText {
            pb.clearContents()
            pb.setString(old, forType: .string)
        }

        JSONOutput.print(["status": "ok", "message": "Pasted \(text.count) chars into terminal"], json: json)
    }
}
