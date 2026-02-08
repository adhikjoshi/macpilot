import ArgumentParser
import Foundation
import IOKit.graphics

private func runOsaScript(_ script: String) -> (exitCode: Int32, stdout: String, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]

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

private func appleScriptBool(_ script: String) -> Bool? {
    let result = runOsaScript(script)
    guard result.exitCode == 0 else { return nil }
    let normalized = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "true" { return true }
    if normalized == "false" { return false }
    return nil
}

private func appleScriptInt(_ script: String) -> Int? {
    let result = runOsaScript(script)
    guard result.exitCode == 0 else { return nil }
    let normalized = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(normalized)
}

private func setSystemVolume(_ value: Int) -> Bool {
    let clamped = min(max(value, 0), 100)
    return runOsaScript("set volume output volume \(clamped)").exitCode == 0
}

private func setMute(_ muted: Bool) -> Bool {
    let script = muted ? "set volume with output muted" : "set volume without output muted"
    return runOsaScript(script).exitCode == 0
}

private func displayService() -> io_service_t? {
    let matching = IOServiceMatching("IODisplayConnect")
    var iterator: io_iterator_t = 0

    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard result == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }

    let service = IOIteratorNext(iterator)
    return service == 0 ? nil : service
}

private func getBrightness() -> Float? {
    guard let service = displayService() else { return nil }
    defer { IOObjectRelease(service) }

    var brightness: Float = 0
    let status = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
    guard status == KERN_SUCCESS else { return nil }
    return min(max(brightness, 0), 1)
}

private func setBrightness(_ value: Float) -> Bool {
    guard let service = displayService() else { return false }
    defer { IOObjectRelease(service) }

    let clamped = min(max(value, 0), 1)
    let status = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, clamped)
    return status == KERN_SUCCESS
}

private func dockAutohideEnabled() -> Bool? {
    appleScriptBool("tell application \"System Events\" to tell dock preferences to get autohide")
}

private func setDockAutohide(_ enabled: Bool) -> Bool {
    let value = enabled ? "true" : "false"
    let script = "tell application \"System Events\" to tell dock preferences to set autohide to \(value)"
    return runOsaScript(script).exitCode == 0
}

private func currentDarkMode() -> Bool? {
    appleScriptBool("tell application \"System Events\" to tell appearance preferences to get dark mode")
}

private func setDarkMode(_ enabled: Bool) -> Bool {
    let value = enabled ? "true" : "false"
    let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)"
    return runOsaScript(script).exitCode == 0
}

struct Audio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Audio controls",
        subcommands: [AudioVolume.self]
    )
}

struct AudioVolume: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Get/set output volume",
        subcommands: [AudioVolumeGet.self, AudioVolumeSet.self, AudioVolumeMute.self, AudioVolumeUnmute.self]
    )

    func run() throws {
        var command = AudioVolumeGet()
        command.json = false
        try command.run()
    }
}

struct AudioVolumeGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get output volume (0-100)")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let volume = appleScriptInt("output volume of (get volume settings)") else {
            JSONOutput.error("Failed to read output volume", json: json)
            throw ExitCode.failure
        }

        guard let muted = appleScriptBool("output muted of (get volume settings)") else {
            JSONOutput.error("Failed to read mute state", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "volume": volume,
            "muted": muted,
            "message": muted ? "Volume: \(volume)% (muted)" : "Volume: \(volume)%",
        ], json: json)
    }
}

struct AudioVolumeSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set output volume (0-100)")

    @Argument(help: "Volume percentage") var value: Int
    @Flag(name: .long) var json = false

    func run() throws {
        guard (0...100).contains(value) else {
            JSONOutput.error("Volume must be between 0 and 100", json: json)
            throw ExitCode.failure
        }

        guard setSystemVolume(value) else {
            JSONOutput.error("Failed to set system volume", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "volume": value,
            "message": "Set volume to \(value)%",
        ], json: json)
    }
}

struct AudioVolumeMute: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mute", abstract: "Mute output volume")

    @Flag(name: .long) var json = false

    func run() throws {
        guard setMute(true) else {
            JSONOutput.error("Failed to mute output", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print(["status": "ok", "message": "Output muted", "muted": true], json: json)
    }
}

struct AudioVolumeUnmute: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unmute", abstract: "Unmute output volume")

    @Flag(name: .long) var json = false

    func run() throws {
        guard setMute(false) else {
            JSONOutput.error("Failed to unmute output", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print(["status": "ok", "message": "Output unmuted", "muted": false], json: json)
    }
}

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Display controls",
        subcommands: [DisplayBrightness.self]
    )
}

struct DisplayBrightness: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightness",
        abstract: "Get/set display brightness",
        subcommands: [DisplayBrightnessGet.self, DisplayBrightnessSet.self]
    )

    func run() throws {
        var command = DisplayBrightnessGet()
        command.json = false
        try command.run()
    }
}

struct DisplayBrightnessGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get brightness (0-100)")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let level = getBrightness() else {
            JSONOutput.error("Failed to read display brightness", json: json)
            throw ExitCode.failure
        }

        let percent = Int(round(level * 100))
        JSONOutput.print([
            "status": "ok",
            "brightness": percent,
            "message": "Brightness: \(percent)%",
        ], json: json)
    }
}

struct DisplayBrightnessSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set brightness (0-100)")

    @Argument(help: "Brightness percentage") var value: Int
    @Flag(name: .long) var json = false

    func run() throws {
        guard (0...100).contains(value) else {
            JSONOutput.error("Brightness must be between 0 and 100", json: json)
            throw ExitCode.failure
        }

        guard setBrightness(Float(value) / 100.0) else {
            JSONOutput.error("Failed to set display brightness", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "brightness": value,
            "message": "Set brightness to \(value)%",
        ], json: json)
    }
}

struct Dock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock",
        abstract: "Dock visibility controls",
        subcommands: [DockShow.self, DockHide.self, DockAutohide.self]
    )
}

struct DockShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Always show Dock")

    @Flag(name: .long) var json = false

    func run() throws {
        guard setDockAutohide(false) else {
            JSONOutput.error("Failed to show Dock", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print(["status": "ok", "autohide": false, "message": "Dock shown"], json: json)
    }
}

struct DockHide: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide", abstract: "Hide Dock by enabling autohide")

    @Flag(name: .long) var json = false

    func run() throws {
        guard setDockAutohide(true) else {
            JSONOutput.error("Failed to hide Dock", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print(["status": "ok", "autohide": true, "message": "Dock hidden (autohide enabled)"], json: json)
    }
}

struct DockAutohide: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "autohide", abstract: "Toggle Dock autohide")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let current = dockAutohideEnabled() else {
            JSONOutput.error("Failed to read Dock autohide state", json: json)
            throw ExitCode.failure
        }

        let next = !current
        guard setDockAutohide(next) else {
            JSONOutput.error("Failed to toggle Dock autohide", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "autohide": next,
            "message": next ? "Dock autohide enabled" : "Dock autohide disabled",
        ], json: json)
    }
}

struct Appearance: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Dark mode controls")

    @Argument(help: "Mode: dark, light, toggle") var mode: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard let current = currentDarkMode() else {
            JSONOutput.error("Failed to read appearance mode", json: json)
            throw ExitCode.failure
        }

        guard let mode else {
            JSONOutput.print([
                "status": "ok",
                "dark": current,
                "message": current ? "Appearance: dark" : "Appearance: light",
            ], json: json)
            return
        }

        let normalized = mode.lowercased()
        let target: Bool

        switch normalized {
        case "dark":
            target = true
        case "light":
            target = false
        case "toggle":
            target = !current
        default:
            JSONOutput.error("Mode must be one of: dark, light, toggle", json: json)
            throw ExitCode.failure
        }

        guard setDarkMode(target) else {
            JSONOutput.error("Failed to set appearance mode", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        JSONOutput.print([
            "status": "ok",
            "dark": target,
            "message": target ? "Appearance set to dark" : "Appearance set to light",
        ], json: json)
    }
}
