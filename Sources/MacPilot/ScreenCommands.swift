import ArgumentParser
import Foundation
import Darwin

private enum ScreenRecordState {
    static let pidFile = "/tmp/macpilot-screen-record.pid"
    static let pathFile = "/tmp/macpilot-screen-record.path"
}

private func screenRecordPID() -> pid_t? {
    guard let text = try? String(contentsOfFile: ScreenRecordState.pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = Int32(text), pid > 0 else {
        return nil
    }
    return pid
}

private func isProcessRunning(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func cleanupScreenRecordFiles() {
    try? FileManager.default.removeItem(atPath: ScreenRecordState.pidFile)
    try? FileManager.default.removeItem(atPath: ScreenRecordState.pathFile)
}

private func writeScreenRecordState(pid: pid_t, path: String) {
    try? "\(pid)".write(toFile: ScreenRecordState.pidFile, atomically: true, encoding: .utf8)
    try? path.write(toFile: ScreenRecordState.pathFile, atomically: true, encoding: .utf8)
}

private func readScreenRecordPath() -> String {
    (try? String(contentsOfFile: ScreenRecordState.pathFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
}

private func defaultRecordingPath() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return "/tmp/macpilot_record_\(formatter.string(from: Date())).mov"
}

struct Screen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Screen utilities",
        subcommands: [ScreenRecord.self]
    )
}

struct ScreenRecord: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Screen recording",
        subcommands: [ScreenRecordStart.self, ScreenRecordStop.self]
    )
}

struct ScreenRecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start screen recording")

    @Option(name: .shortAndLong, help: "Output movie path (.mov)") var output: String?
    @Flag(name: .long) var json = false

    func run() throws {
        if let pid = screenRecordPID(), isProcessRunning(pid) {
            JSONOutput.error("Screen recording already running (pid: \(pid))", json: json)
            throw ExitCode.failure
        }

        cleanupScreenRecordFiles()

        var outputPath = output ?? defaultRecordingPath()
        if URL(fileURLWithPath: outputPath).pathExtension.isEmpty {
            outputPath += ".mov"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-v", outputPath]

        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            JSONOutput.error("Failed to start screen recording: \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        let pid = task.processIdentifier
        writeScreenRecordState(pid: pid, path: outputPath)

        usleep(120_000)
        if !isProcessRunning(pid) {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cleanupScreenRecordFiles()
            JSONOutput.error(stderr.isEmpty ? "Screen recording failed to start" : stderr, json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "message": "Screen recording started",
            "pid": Int(pid),
            "path": outputPath,
        ], json: json)
    }
}

struct ScreenRecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop screen recording")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = screenRecordPID() else {
            JSONOutput.error("No active screen recording", json: json)
            throw ExitCode.failure
        }

        let outputPath = readScreenRecordPath()

        if isProcessRunning(pid) {
            _ = Darwin.kill(pid, SIGINT)
            let deadline = Date().addingTimeInterval(5.0)
            while isProcessRunning(pid), Date() < deadline {
                usleep(100_000)
            }
            if isProcessRunning(pid) {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }

        cleanupScreenRecordFiles()
        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "message": "Screen recording stopped",
            "path": outputPath,
        ], json: json)
    }
}
