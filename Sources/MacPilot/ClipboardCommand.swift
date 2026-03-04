import ArgumentParser
import AppKit
import Foundation

// MARK: - Clipboard History Storage

private enum ClipboardHistoryStore {
    static let maxEntries = 50
    static var directory: String {
        let dir = NSString(string: "~/.macpilot").expandingTildeInPath
        return dir
    }
    static var historyFile: String { "\(directory)/clipboard-history.json" }
    static var imagesDir: String { "\(directory)/clipboard-images" }

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
    }

    static func load() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: historyFile)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    static func save(_ entries: [[String: Any]]) {
        ensureDirectories()
        // Enforce max entries cap — remove oldest (last) entries if over limit
        let trimmed = Array(entries.prefix(maxEntries))
        guard let data = try? JSONSerialization.data(withJSONObject: trimmed, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: historyFile))
    }

    static func addEntry(_ entry: [String: Any]) {
        var entries = load()
        entries.insert(entry, at: 0)
        // Remove oldest entries beyond maxEntries
        if entries.count > maxEntries {
            // Clean up image files for removed entries
            let removed = entries[maxEntries...]
            for entry in removed {
                if let imagePath = entry["imagePath"] as? String {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }
            }
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: historyFile)
        try? FileManager.default.removeItem(atPath: imagesDir)
        try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
    }
}

// MARK: - Clipboard History Daemon State

private enum ClipboardDaemonState {
    static let pidFile = "/tmp/macpilot-clipboard-history.pid"

    static func readPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(text), pid > 0 else {
            return nil
        }
        return pid
    }

    static func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    static func writePID(_ pid: pid_t) {
        try? "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    static func cleanup() {
        try? FileManager.default.removeItem(atPath: pidFile)
    }
}

// MARK: - Commands

struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clipboard manager",
        subcommands: [
            ClipboardGet.self, ClipboardSet.self, ClipboardImage.self, ClipboardWatch.self,
            ClipboardInfo.self, ClipboardTypes.self, ClipboardClear.self,
            ClipboardPaste.self, ClipboardCopy.self, ClipboardSave.self,
            ClipboardHistory.self,
        ]
    )
}

struct ClipboardGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get clipboard contents")

    @Flag(name: .long) var json = false

    func run() {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string) ?? ""
        if json {
            JSONOutput.print(["status": "ok", "text": text], json: true)
        } else {
            print(text)
        }
    }
}

struct ClipboardSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set clipboard contents")

    @Argument(help: "Text to set") var text: String
    @Flag(name: .long) var json = false

    func run() {
        flashIndicatorIfRunning()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        JSONOutput.print(["status": "ok", "message": "Clipboard set (\(text.count) chars)"], json: json)
    }
}

struct ClipboardImage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "image", abstract: "Set clipboard image from file path")

    @Argument(help: "Image file path") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        let resolvedPath = URL(fileURLWithPath: path).standardized.path
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            JSONOutput.error("Image file not found: \(resolvedPath)", json: json)
            throw ExitCode.failure
        }

        guard let image = NSImage(contentsOfFile: resolvedPath) else {
            JSONOutput.error("Failed to load image: \(resolvedPath)", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects([image]) else {
            JSONOutput.error("Failed to write image to clipboard", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Clipboard image set",
            "path": resolvedPath,
        ], json: json)
    }
}

struct ClipboardWatch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Watch clipboard for changes")

    @Option(name: .long, help: "Duration in seconds to watch") var duration: Double = 10
    @Option(name: .long, help: "Poll interval in milliseconds") var interval: Int = 300
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(duration)
        let pb = NSPasteboard.general
        var lastChangeCount = pb.changeCount
        var changes: [[String: Any]] = []

        if !json {
            print("Watching clipboard for \(Int(duration))s...")
        }

        while Date() < deadline {
            let currentCount = pb.changeCount
            if currentCount != lastChangeCount {
                let text = pb.string(forType: .string) ?? ""
                let preview = String(text.prefix(100))
                let change: [String: Any] = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "preview": preview,
                    "length": text.count,
                    "changeCount": currentCount,
                ]
                changes.append(change)
                if !json {
                    print("  [\(changes.count)] \(preview.prefix(60))\(text.count > 60 ? "..." : "") (\(text.count) chars)")
                }
                lastChangeCount = currentCount
            }
            usleep(UInt32(interval) * 1000)
        }

        if json {
            JSONOutput.print([
                "status": "ok",
                "duration": duration,
                "changeCount": changes.count,
                "changes": changes,
            ], json: true)
        } else {
            print("Done. \(changes.count) clipboard change(s) detected.")
        }
    }
}

// MARK: - clipboard info

struct ClipboardInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show clipboard content type, preview, and size")

    @Flag(name: .long) var json = false

    func run() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let changeCount = pb.changeCount

        var contentType = "empty"
        var preview = ""
        var size = 0

        if let text = pb.string(forType: .string) {
            contentType = "text"
            preview = String(text.prefix(200))
            size = text.utf8.count
        } else if let _ = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            contentType = "image"
            let imgData = pb.data(forType: .tiff) ?? pb.data(forType: .png) ?? Data()
            size = imgData.count
            preview = "[\(size) bytes image data]"
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            contentType = "file"
            preview = urls.map { $0.lastPathComponent }.joined(separator: ", ")
            size = urls.count
        } else if let rtf = pb.data(forType: .rtf) {
            contentType = "rtf"
            size = rtf.count
            preview = "[RTF data, \(size) bytes]"
        }

        JSONOutput.print([
            "status": "ok",
            "contentType": contentType,
            "preview": preview,
            "size": size,
            "changeCount": changeCount,
            "typeCount": types.count,
            "message": "\(contentType) on clipboard (\(size) \(contentType == "file" ? "files" : "bytes"))",
        ], json: json)
    }
}

// MARK: - clipboard types

struct ClipboardTypes: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "types", abstract: "List all UTI types on clipboard")

    @Flag(name: .long) var json = false

    func run() {
        let pb = NSPasteboard.general
        let types = (pb.types ?? []).map { $0.rawValue }

        if json {
            JSONOutput.print([
                "status": "ok",
                "types": types,
                "count": types.count,
            ], json: true)
        } else {
            if types.isEmpty {
                print("Clipboard is empty")
            } else {
                for t in types { print(t) }
            }
        }
    }
}

// MARK: - clipboard clear

struct ClipboardClear: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear clipboard")

    @Flag(name: .long) var json = false

    func run() {
        flashIndicatorIfRunning()
        let pb = NSPasteboard.general
        pb.clearContents()
        JSONOutput.print(["status": "ok", "message": "Clipboard cleared"], json: json)
    }
}

// MARK: - clipboard paste

struct ClipboardPaste: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "paste", abstract: "Simulate Cmd+V paste")

    @Flag(name: .long) var json = false

    func run() {
        flashIndicatorIfRunning()
        KeyboardController.pressCombo("cmd+v")
        JSONOutput.print(["status": "ok", "message": "Paste simulated (Cmd+V)"], json: json)
    }
}

// MARK: - clipboard copy (files)

struct ClipboardCopy: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "copy", abstract: "Copy file(s) to clipboard")

    @Argument(parsing: .remaining, help: "File path(s) to copy") var paths: [String]
    @Flag(name: .long) var json = false

    func run() throws {
        guard !paths.isEmpty else {
            JSONOutput.error("No file paths provided", json: json)
            throw ExitCode.failure
        }

        var urls: [URL] = []
        for path in paths {
            let resolved = URL(fileURLWithPath: path).standardized
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                JSONOutput.error("File not found: \(resolved.path)", json: json)
                throw ExitCode.failure
            }
            urls.append(resolved)
        }

        flashIndicatorIfRunning()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])

        JSONOutput.print([
            "status": "ok",
            "message": "Copied \(urls.count) file(s) to clipboard",
            "files": urls.map { $0.path },
        ], json: json)
    }
}

// MARK: - clipboard save

struct ClipboardSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save clipboard contents to a file")

    @Argument(help: "Output file path") var path: String
    @Flag(name: .long) var json = false

    func run() throws {
        let pb = NSPasteboard.general
        let resolvedPath = URL(fileURLWithPath: path).standardized.path

        // Try text
        if let text = pb.string(forType: .string) {
            let ext = URL(fileURLWithPath: resolvedPath).pathExtension.lowercased()
            let finalPath = ext.isEmpty ? resolvedPath + ".txt" : resolvedPath
            try text.write(toFile: finalPath, atomically: true, encoding: .utf8)
            JSONOutput.print([
                "status": "ok",
                "message": "Saved clipboard text to \(finalPath)",
                "path": finalPath,
                "bytes": text.utf8.count,
            ], json: json)
            return
        }

        // Try image
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData) {
            let ext = URL(fileURLWithPath: resolvedPath).pathExtension.lowercased()
            let finalPath = ext.isEmpty ? resolvedPath + ".png" : resolvedPath
            let fileType: NSBitmapImageRep.FileType = ext == "jpg" || ext == "jpeg" ? .jpeg : .png
            guard let imgData = bitmap.representation(using: fileType, properties: [:]) else {
                JSONOutput.error("Failed to encode clipboard image", json: json)
                throw ExitCode.failure
            }
            try imgData.write(to: URL(fileURLWithPath: finalPath))
            JSONOutput.print([
                "status": "ok",
                "message": "Saved clipboard image to \(finalPath)",
                "path": finalPath,
                "bytes": imgData.count,
            ], json: json)
            return
        }

        // Try RTF
        if let rtfData = pb.data(forType: .rtf) {
            let ext = URL(fileURLWithPath: resolvedPath).pathExtension.lowercased()
            let finalPath = ext.isEmpty ? resolvedPath + ".rtf" : resolvedPath
            try rtfData.write(to: URL(fileURLWithPath: finalPath))
            JSONOutput.print([
                "status": "ok",
                "message": "Saved clipboard RTF to \(finalPath)",
                "path": finalPath,
                "bytes": rtfData.count,
            ], json: json)
            return
        }

        JSONOutput.error("Clipboard is empty or contains unsupported content", json: json)
        throw ExitCode.failure
    }
}

// MARK: - clipboard history

struct ClipboardHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Clipboard history management",
        subcommands: [
            ClipboardHistoryList.self,
            ClipboardHistorySearch.self,
            ClipboardHistoryStart.self,
            ClipboardHistoryStop.self,
            ClipboardHistoryClear.self,
        ]
    )
}

// MARK: - clipboard history list

struct ClipboardHistoryList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show stored clipboard history")

    @Option(name: .long, help: "Maximum entries to show") var limit: Int = 20
    @Flag(name: .long) var json = false

    func run() {
        let entries = ClipboardHistoryStore.load()
        let limited = Array(entries.prefix(limit))

        if json {
            JSONOutput.print([
                "status": "ok",
                "entries": limited,
                "count": limited.count,
                "total": entries.count,
            ], json: true)
        } else {
            if entries.isEmpty {
                print("No clipboard history. Start recording with: clipboard history start")
            } else {
                for (i, entry) in limited.enumerated() {
                    let type = entry["type"] as? String ?? "unknown"
                    let preview = entry["preview"] as? String ?? ""
                    let timestamp = entry["timestamp"] as? String ?? ""
                    let short = String(preview.prefix(80))
                    print("  [\(i + 1)] \(timestamp) [\(type)] \(short)\(preview.count > 80 ? "..." : "")")
                }
                print("\(entries.count) total entries")
            }
        }
    }
}

// MARK: - clipboard history search

struct ClipboardHistorySearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search clipboard history")

    @Argument(help: "Search query (case-insensitive)") var query: String
    @Option(name: .long, help: "Maximum results") var limit: Int = 20
    @Flag(name: .long) var json = false

    func run() {
        let entries = ClipboardHistoryStore.load()
        let lowerQuery = query.lowercased()

        let matches = entries.filter { entry in
            if let preview = entry["preview"] as? String, preview.lowercased().contains(lowerQuery) { return true }
            if let content = entry["content"] as? String, content.lowercased().contains(lowerQuery) { return true }
            return false
        }
        let limited = Array(matches.prefix(limit))

        if json {
            JSONOutput.print([
                "status": "ok",
                "query": query,
                "entries": limited,
                "count": limited.count,
                "totalMatches": matches.count,
            ], json: true)
        } else {
            if matches.isEmpty {
                print("No matches for '\(query)'")
            } else {
                for (i, entry) in limited.enumerated() {
                    let type = entry["type"] as? String ?? "unknown"
                    let preview = entry["preview"] as? String ?? ""
                    let timestamp = entry["timestamp"] as? String ?? ""
                    let short = String(preview.prefix(80))
                    print("  [\(i + 1)] \(timestamp) [\(type)] \(short)\(preview.count > 80 ? "..." : "")")
                }
                if matches.count > limit {
                    print("Showing \(limit) of \(matches.count) matches")
                }
            }
        }
    }
}

// MARK: - clipboard history start (daemon)

struct ClipboardHistoryStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start clipboard history daemon")

    @Option(name: .long, help: "Max history entries") var limit: Int = 50
    @Option(name: .long, help: "Poll interval in milliseconds") var interval: Int = 500
    @Flag(name: .long) var json = false

    func run() throws {
        // Check if daemon env var is set — if so, we ARE the daemon
        if ProcessInfo.processInfo.environment["MACPILOT_CLIPBOARD_DAEMON"] == "1" {
            runDaemon(interval: interval)
            return
        }

        // Check if already running
        if ClipboardDaemonState.isRunning() {
            JSONOutput.error("Clipboard history daemon already running (pid: \(ClipboardDaemonState.readPID() ?? 0))", json: json)
            throw ExitCode.failure
        }

        ClipboardHistoryStore.ensureDirectories()

        // Spawn self as daemon
        let execPath = ProcessInfo.processInfo.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: execPath)
        task.arguments = ["clipboard", "history", "start", "--interval", "\(interval)", "--limit", "\(limit)"]
        task.environment = ProcessInfo.processInfo.environment.merging(["MACPILOT_CLIPBOARD_DAEMON": "1"]) { _, new in new }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            JSONOutput.error("Failed to start daemon: \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        let pid = task.processIdentifier
        ClipboardDaemonState.writePID(pid)

        usleep(200_000)
        guard ClipboardDaemonState.isRunning() else {
            ClipboardDaemonState.cleanup()
            JSONOutput.error("Daemon failed to start", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Clipboard history daemon started",
            "pid": Int(pid),
            "interval": interval,
            "maxEntries": limit,
        ], json: json)
    }

    private func runDaemon(interval: Int) {
        let pb = NSPasteboard.general
        var lastChangeCount = pb.changeCount

        signal(SIGTERM) { _ in
            ClipboardDaemonState.cleanup()
            Darwin.exit(0)
        }
        signal(SIGINT) { _ in
            ClipboardDaemonState.cleanup()
            Darwin.exit(0)
        }

        while true {
            let currentCount = pb.changeCount
            if currentCount != lastChangeCount {
                lastChangeCount = currentCount
                captureCurrentClipboard(pb)
            }
            usleep(UInt32(interval) * 1000)
        }
    }

    private func captureCurrentClipboard(_ pb: NSPasteboard) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var entry: [String: Any] = ["timestamp": timestamp]

        if let text = pb.string(forType: .string) {
            entry["type"] = "text"
            entry["preview"] = String(text.prefix(200))
            entry["content"] = text
            entry["size"] = text.utf8.count
        } else if let tiffData = pb.data(forType: .tiff),
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) {
            let imageName = "clip_\(UUID().uuidString.prefix(8)).png"
            let imagePath = "\(ClipboardHistoryStore.imagesDir)/\(imageName)"
            try? pngData.write(to: URL(fileURLWithPath: imagePath))
            entry["type"] = "image"
            entry["imagePath"] = imagePath
            entry["preview"] = "[\(pngData.count) bytes PNG]"
            entry["size"] = pngData.count
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            entry["type"] = "file"
            let files = urls.map { $0.path }
            entry["files"] = files
            entry["preview"] = files.joined(separator: ", ")
            entry["size"] = files.count
        } else {
            entry["type"] = "other"
            entry["preview"] = "Unknown content"
            entry["size"] = 0
        }

        ClipboardHistoryStore.addEntry(entry)
    }
}

// MARK: - clipboard history stop

struct ClipboardHistoryStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop clipboard history daemon")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = ClipboardDaemonState.readPID(), ClipboardDaemonState.isRunning() else {
            JSONOutput.error("No clipboard history daemon running", json: json)
            throw ExitCode.failure
        }

        Darwin.kill(pid, SIGTERM)
        usleep(500_000)
        ClipboardDaemonState.cleanup()

        JSONOutput.print([
            "status": "ok",
            "message": "Clipboard history daemon stopped",
        ], json: json)
    }
}

// MARK: - clipboard history clear

struct ClipboardHistoryClear: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear clipboard history and saved images")

    @Flag(name: .long) var json = false

    func run() {
        ClipboardHistoryStore.clear()
        JSONOutput.print(["status": "ok", "message": "Clipboard history cleared"], json: json)
    }
}
