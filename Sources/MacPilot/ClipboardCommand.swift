import ArgumentParser
import AppKit
import Foundation

struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clipboard get/set",
        subcommands: [ClipboardGet.self, ClipboardSet.self]
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        JSONOutput.print(["status": "ok", "message": "Clipboard set (\(text.count) chars)"], json: json)
    }
}
