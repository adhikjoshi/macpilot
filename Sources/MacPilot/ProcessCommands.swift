import ArgumentParser
import AppKit
import Foundation
import Darwin

private struct ProcessEntry {
    let pid: pid_t
    let command: String

    var name: String {
        URL(fileURLWithPath: command).lastPathComponent
    }
}

private func runProcessCommand(_ executable: String, _ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return (1, "", error.localizedDescription)
    }

    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (task.terminationStatus, stdout, stderr)
}

private func listAllProcesses() -> [ProcessEntry] {
    let result = runProcessCommand("/bin/ps", ["-axo", "pid=,comm="])
    guard result.exitCode == 0 else {
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return ProcessEntry(pid: app.processIdentifier, command: name)
        }
    }

    return result.stdout
        .split(separator: "\n")
        .compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return ProcessEntry(pid: pid, command: String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
}

struct ProcessControl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Process management",
        subcommands: [ProcessList.self, ProcessKill.self]
    )
}

struct ProcessList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List running processes")

    @Flag(name: .long) var json = false

    func run() throws {
        let processes = listAllProcesses()

        if json {
            let payload = processes.map { ["pid": Int($0.pid), "name": $0.name, "command": $0.command] }
            JSONOutput.printArray(payload, json: true)
        } else {
            for process in processes {
                print("\(process.pid)\t\(process.name)\t\(process.command)")
            }
        }
    }
}

struct ProcessKill: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Kill process by pid or name")

    @Argument(help: "Process pid or name substring") var target: String
    @Flag(name: .long, help: "Force kill with SIGKILL") var force = false
    @Flag(name: .long) var json = false

    func run() throws {
        let processes = listAllProcesses()
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let matches: [ProcessEntry]
        if let pid = Int32(target) {
            matches = processes.filter { $0.pid == pid }
        } else {
            matches = processes.filter {
                $0.name.localizedCaseInsensitiveContains(target) ||
                    $0.command.localizedCaseInsensitiveContains(target)
            }
        }

        guard !matches.isEmpty else {
            JSONOutput.error("No process matches '\(target)'", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        var killed: [[String: Any]] = []

        for entry in matches {
            if entry.pid == currentPID {
                JSONOutput.error("Refusing to kill current MacPilot process (pid: \(entry.pid))", json: json)
                throw ExitCode.failure
            }

            if let reason = Safety.validateQuit(appName: entry.name) {
                JSONOutput.error(reason, json: json)
                throw ExitCode.failure
            }

            let signal = force ? SIGKILL : SIGTERM
            guard Darwin.kill(entry.pid, signal) == 0 else {
                JSONOutput.error("Failed to kill pid \(entry.pid): \(String(cString: strerror(errno)))", json: json)
                throw ExitCode.failure
            }

            killed.append([
                "pid": Int(entry.pid),
                "name": entry.name,
                "signal": signal,
            ])
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Killed \(killed.count) process(es)",
            "killed": killed,
        ], json: json)
    }
}
