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
        // Find our own .app bundle path
        let execPath = ProcessInfo.processInfo.arguments[0]
        let bundlePath = findBundlePath(execPath)

        guard let appPath = bundlePath else {
            JSONOutput.error("Cannot find .app bundle for re-launch. Exec path: \(execPath)", json: json)
            throw ExitCode.failure
        }

        // Create temp files for output
        let tmpDir = FileManager.default.temporaryDirectory
        let outFile = tmpDir.appendingPathComponent("macpilot_run_\(ProcessInfo.processInfo.processIdentifier)_out.txt")
        let errFile = tmpDir.appendingPathComponent("macpilot_run_\(ProcessInfo.processInfo.processIdentifier)_err.txt")

        // Clean up any existing files
        try? FileManager.default.removeItem(at: outFile)
        try? FileManager.default.removeItem(at: errFile)
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }

        // Build the open command
        // open -W -a /path/to/MacPilot.app --stdout /tmp/out --stderr /tmp/err --args <subcommand> <args...>
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

        // Read and print output
        let stdout = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""

        if !stdout.isEmpty {
            print(stdout, terminator: "")
        }
        if !stderr.isEmpty {
            FileHandle.standardError.write(Data(stderr.utf8))
        }

        if task.terminationStatus != 0 {
            throw ExitCode(task.terminationStatus)
        }
    }

    /// Walk up from the executable to find the .app bundle
    private func findBundlePath(_ execPath: String) -> String? {
        var url = URL(fileURLWithPath: execPath).standardized
        // Walk up looking for .app
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                return url.path
            }
        }
        // Fallback: check if we know the standard path
        let standardPath = "/Users/admin/clawd/tools/macpilot/MacPilot.app"
        if FileManager.default.fileExists(atPath: standardPath) {
            return standardPath
        }
        return nil
    }
}
