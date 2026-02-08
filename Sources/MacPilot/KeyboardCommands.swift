import ArgumentParser
import CoreGraphics
import CoreAudio
import Foundation
import Carbon.HIToolbox

struct KeyboardActionResult {
    let alertSoundDetected: Bool
}

private func printKeyboardResult(
    message: String,
    result: KeyboardActionResult,
    detectErrors: Bool,
    warningMessage: String,
    json: Bool
) {
    let modalDialog = (detectErrors && result.alertSoundDetected) ? detectFrontmostModalDialog() : nil
    var payload: [String: Any] = [
        "status": (detectErrors && result.alertSoundDetected) ? "warning" : "ok",
        "message": message,
    ]

    if detectErrors {
        payload["alertSoundDetected"] = result.alertSoundDetected
        if result.alertSoundDetected {
            payload["warning"] = warningMessage
            if let modalDialog {
                payload["modalDialog"] = modalDialogPayload(modalDialog)
            }
        }
    }

    JSONOutput.print(payload, json: json)

    if detectErrors, result.alertSoundDetected, !json {
        Swift.print(warningMessage)
        if let modalDialog {
            let title = modalDialog.title.isEmpty ? "Modal dialog detected" : "Modal dialog detected: \(modalDialog.title)"
            if modalDialog.buttons.isEmpty {
                Swift.print(title)
            } else {
                Swift.print("\(title) [\(modalDialog.buttons.joined(separator: ", "))]")
            }
        }
    }
}

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
    @Option(name: .long, help: "Delay between each typed character in seconds (default: 0.012)")
    var interval: Double = 0.012
    @Flag(name: [.customLong("detect-errors"), .customLong("strict")], help: "Detect system alert sounds that indicate the input was rejected")
    var detectErrors = false
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "keyboard typing")
        flashIndicatorIfRunning()
        let result = KeyboardController.typeText(
            text,
            interval: max(interval, 0),
            alertDetectionWindow: detectErrors ? KeyboardController.defaultAlertDetectionWindow : nil
        )
        printKeyboardResult(
            message: "Typed \(text.count) characters",
            result: result,
            detectErrors: detectErrors,
            warningMessage: KeyboardController.alertTypingWarning,
            json: json
        )
    }
}

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press key combo (e.g. cmd+c, enter)")

    @Argument(help: "Key combo like cmd+c, shift+enter, etc.") var combo: String
    @Flag(name: [.customLong("detect-errors"), .customLong("strict")], help: "Detect system alert sounds that indicate the key combo was rejected")
    var detectErrors = false
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "keyboard shortcuts")
        flashIndicatorIfRunning()
        let result = KeyboardController.pressCombo(
            combo,
            alertDetectionWindow: detectErrors ? KeyboardController.defaultAlertDetectionWindow : nil
        )
        printKeyboardResult(
            message: "Pressed \(combo)",
            result: result,
            detectErrors: detectErrors,
            warningMessage: KeyboardController.alertKeyComboWarning,
            json: json
        )
    }
}

struct Shortcut: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shortcut", abstract: "Press keyboard shortcut combo")

    @Argument(help: "Shortcut combo like cmd+c, cmd+shift+v, etc.") var combo: String
    @Flag(name: [.customLong("detect-errors"), .customLong("strict")], help: "Detect system alert sounds that indicate the key combo was rejected")
    var detectErrors = false
    @Flag(name: .long) var json = false

    func run() throws {
        try requireActiveUserSession(json: json, actionDescription: "keyboard shortcuts")
        flashIndicatorIfRunning()
        let result = KeyboardController.pressCombo(
            combo,
            alertDetectionWindow: detectErrors ? KeyboardController.defaultAlertDetectionWindow : nil
        )
        printKeyboardResult(
            message: "Pressed \(combo)",
            result: result,
            detectErrors: detectErrors,
            warningMessage: KeyboardController.alertKeyComboWarning,
            json: json
        )
    }
}

enum KeyboardController {
    static let defaultAlertDetectionWindow: TimeInterval = 0.2
    static let alertKeyComboWarning = "warning: system rejected this key combination (alert sound detected)"
    static let alertTypingWarning = "warning: system rejected this keyboard input (alert sound detected)"
    private static let defaultTypeInterval: TimeInterval = 0.012

    @discardableResult
    static func typeText(
        _ text: String,
        interval: TimeInterval = defaultTypeInterval,
        alertDetectionWindow: TimeInterval? = nil
    ) -> KeyboardActionResult {
        return runKeyboardAction(alertDetectionWindow: alertDetectionWindow) {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            let clampedInterval = max(interval, 0)

            for character in text {
                let utf16 = Array(String(character).utf16)
                guard !utf16.isEmpty else { continue }

                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    continue
                }

                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)

                if clampedInterval > 0 {
                    usleep(microseconds(from: clampedInterval))
                }
            }
        }
    }

    @discardableResult
    static func pressCombo(_ combo: String, alertDetectionWindow: TimeInterval? = nil) -> KeyboardActionResult {
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

        return runKeyboardAction(alertDetectionWindow: alertDetectionWindow) {
            let src = CGEventSource(stateID: .combinedSessionState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
                down.flags = flags
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                up.flags = flags
                up.post(tap: .cghidEventTap)
            }
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

    private static func runKeyboardAction(
        alertDetectionWindow: TimeInterval?,
        action: () -> Void
    ) -> KeyboardActionResult {
        guard let detectionWindow = alertDetectionWindow, detectionWindow > 0 else {
            action()
            return KeyboardActionResult(alertSoundDetected: false)
        }

        let baseline = SystemAlertSoundDetector.activeOutputProcessIdentifiers()
        action()
        let detected = SystemAlertSoundDetector.detectAlertSound(
            baselineIdentifiers: baseline,
            duration: detectionWindow
        )
        return KeyboardActionResult(alertSoundDetected: detected)
    }

    private static func microseconds(from seconds: TimeInterval) -> useconds_t {
        let clamped = max(0, min(seconds, Double(UInt32.max) / 1_000_000.0))
        return useconds_t(clamped * 1_000_000.0)
    }
}

private enum SystemAlertSoundDetector {
    private static let pollIntervalMicroseconds: useconds_t = 20_000

    static func detectAlertSound(
        baselineIdentifiers: Set<String>,
        duration: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            let current = activeOutputProcessIdentifiers()
            if !current.subtracting(baselineIdentifiers).isEmpty {
                return true
            }
            usleep(pollIntervalMicroseconds)
        }
        return false
    }

    static func activeOutputProcessIdentifiers() -> Set<String> {
        var identifiers: Set<String> = []
        for processID in processObjectIDs() where isRunningOutput(processID) {
            if let pid = processPID(processID), pid > 0 {
                identifiers.insert("pid:\(pid)")
            } else {
                identifiers.insert("obj:\(processID)")
            }
        }
        return identifiers
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return []
        }
        return processIDs
    }

    private static func isRunningOutput(_ processID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    private static func processPID(_ processID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &pid)
        guard status == noErr else { return nil }
        return pid
    }
}
