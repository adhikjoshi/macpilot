import ArgumentParser
import AppKit
import Foundation

struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clipboard get/set",
        subcommands: [ClipboardGet.self, ClipboardSet.self, ClipboardImage.self, ClipboardWatch.self]
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
