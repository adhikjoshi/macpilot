import ArgumentParser
import AppKit
import Foundation

struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clipboard get/set",
        subcommands: [ClipboardGet.self, ClipboardSet.self, ClipboardImage.self]
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
