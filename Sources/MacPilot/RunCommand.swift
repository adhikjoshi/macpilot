import ArgumentParser
import ApplicationServices
import Foundation

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Re-launch a MacPilot subcommand via 'open -W' for AX access"
    )

    @Argument(parsing: .allUnrecognized, help: "Subcommand and arguments to pass")
    var args: [String] = []

    @Flag(name: .long) var json = false

    func run() throws {
        let execPath = ProcessInfo.processInfo.arguments[0]
        let bundlePath = findBundlePath(execPath)

        guard let appPath = bundlePath else {
            JSONOutput.error(
                "Cannot find .app bundle for re-launch. Set MACPILOT_APP_PATH or build one with: bash scripts/build-app.sh",
                json: json
            )
            throw ExitCode.failure
        }

        let tmpDir = FileManager.default.temporaryDirectory
        let outFile = tmpDir.appendingPathComponent("macpilot_run_\(ProcessInfo.processInfo.processIdentifier)_out.txt")
        let errFile = tmpDir.appendingPathComponent("macpilot_run_\(ProcessInfo.processInfo.processIdentifier)_err.txt")

        try? FileManager.default.removeItem(at: outFile)
        try? FileManager.default.removeItem(at: errFile)
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }

        var openArgs = ["-W", "-a", appPath, "--stdout", outFile.path, "--stderr", errFile.path]
        if !args.isEmpty {
            openArgs.append("--args")
            openArgs.append(contentsOf: args)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = openArgs
        try task.run()
        task.waitUntilExit()

        let stdout = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""

        if !stdout.isEmpty { print(stdout, terminator: "") }
        if !stderr.isEmpty { FileHandle.standardError.write(Data(stderr.utf8)) }

        if task.terminationStatus != 0 {
            throw ExitCode(task.terminationStatus)
        }
    }

    private func findBundlePath(_ execPath: String) -> String? {
        let fm = FileManager.default

        if let overridePath = ProcessInfo.processInfo.environment["MACPILOT_APP_PATH"], !overridePath.isEmpty {
            if fm.fileExists(atPath: overridePath) {
                return overridePath
            }
            let expanded = NSString(string: overridePath).expandingTildeInPath
            if fm.fileExists(atPath: expanded) {
                return expanded
            }
        }

        var url = URL(fileURLWithPath: execPath).standardizedFileURL
        for _ in 0..<8 {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if bundleURL.pathExtension == "app", fm.fileExists(atPath: bundleURL.path) {
            return bundleURL.path
        }

        return nil
    }
}
