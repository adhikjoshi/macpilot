import ArgumentParser
import CoreGraphics
import Foundation
import Carbon.HIToolbox

struct Keyboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard",
        abstract: "Keyboard actions",
        subcommands: [TypeText.self, Key.self, Shortcut.self]
    )
}

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text string")

    @Argument(help: "Text to type") var text: String
    @Flag(name: .long) var json = false

    func run() {
        KeyboardController.typeText(text)
        JSONOutput.print(["status": "ok", "message": "Typed \(text.count) characters"], json: json)
    }
}

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press key combo (e.g. cmd+c, enter)")

    @Argument(help: "Key combo like cmd+c, shift+enter, etc.") var combo: String
    @Flag(name: .long) var json = false

    func run() {
        KeyboardController.pressCombo(combo)
        JSONOutput.print(["status": "ok", "message": "Pressed \(combo)"], json: json)
    }
}

struct Shortcut: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shortcut", abstract: "Press keyboard shortcut combo")

    @Argument(help: "Shortcut combo like cmd+c, cmd+shift+v, etc.") var combo: String
    @Flag(name: .long) var json = false

    func run() {
        KeyboardController.pressCombo(combo)
        JSONOutput.print(["status": "ok", "message": "Pressed \(combo)"], json: json)
    }
}

enum KeyboardController {
    static func typeText(_ text: String) {
        for char in text {
            let str = String(char)
            let src = CGEventSource(stateID: .hidSystemState)
            if let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                let utf16 = Array(str.utf16)
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
            usleep(12000)
        }
    }

    static func pressCombo(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode = 0

        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyCode = keyCodeFor(part)
            }
        }

        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    static func keyCodeFor(_ key: String) -> CGKeyCode {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "space": 49, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53,
            "up": 126, "down": 125, "left": 123, "right": 124,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "forwarddelete": 117,
        ]
        return map[key] ?? 0
    }
}
