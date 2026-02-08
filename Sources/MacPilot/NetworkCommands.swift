import ArgumentParser
import Foundation

private func runNetworkTool(_ executable: String, _ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments

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

private func discoverInterfaces() -> [String] {
    let result = runNetworkTool("/sbin/ifconfig", ["-l"])
    guard result.exitCode == 0 else { return [] }
    return result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init)
}

private func discoverWiFiDevice() -> String? {
    let result = runNetworkTool("/usr/sbin/networksetup", ["-listallhardwareports"])
    guard result.exitCode == 0 else { return nil }

    let lines = result.stdout.split(separator: "\n").map(String.init)
    var sawWiFiHeader = false

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Hardware Port:") {
            let port = line.replacingOccurrences(of: "Hardware Port:", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            sawWiFiHeader = port.contains("wi-fi") || port.contains("airport")
            continue
        }

        if sawWiFiHeader, line.hasPrefix("Device:") {
            let dev = line.replacingOccurrences(of: "Device:", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !dev.isEmpty {
                return dev
            }
        }
    }

    return nil
}

private func ipAddress(for interface: String) -> String? {
    let result = runNetworkTool("/usr/sbin/ipconfig", ["getifaddr", interface])
    guard result.exitCode == 0 else { return nil }
    let ip = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return ip.isEmpty ? nil : ip
}

private func interfaceIsActive(_ interface: String) -> Bool {
    let result = runNetworkTool("/sbin/ifconfig", [interface])
    guard result.exitCode == 0 else { return false }
    return result.stdout.localizedCaseInsensitiveContains("status: active")
}

struct Network: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Network information",
        subcommands: [NetworkWiFiName.self, NetworkIP.self, NetworkInterfaces.self]
    )

    func run() throws {
        var defaultCommand = NetworkInterfaces()
        defaultCommand.json = false
        try defaultCommand.run()
    }
}

struct NetworkWiFiName: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wifi-name", abstract: "Show current Wi-Fi SSID")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let device = discoverWiFiDevice() else {
            JSONOutput.error("Could not find Wi-Fi interface", json: json)
            throw ExitCode.failure
        }

        let result = runNetworkTool("/usr/sbin/networksetup", ["-getairportnetwork", device])
        guard result.exitCode == 0 else {
            JSONOutput.error(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), json: json)
            throw ExitCode.failure
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = output
            .replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
            .replacingOccurrences(of: "You are not associated with an AirPort network.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        JSONOutput.print([
            "status": "ok",
            "interface": device,
            "ssid": ssid,
            "message": ssid.isEmpty ? "Wi-Fi not connected" : "Wi-Fi: \(ssid)",
        ], json: json)
    }
}

struct NetworkIP: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ip", abstract: "Show primary IPv4 address")

    @Flag(name: .long) var json = false

    func run() throws {
        var candidates: [String] = []
        if let wifi = discoverWiFiDevice() { candidates.append(wifi) }
        candidates.append(contentsOf: discoverInterfaces())

        var checked = Set<String>()
        for interface in candidates where !checked.contains(interface) {
            checked.insert(interface)
            if let ip = ipAddress(for: interface) {
                JSONOutput.print([
                    "status": "ok",
                    "interface": interface,
                    "ip": ip,
                    "message": "\(interface): \(ip)",
                ], json: json)
                return
            }
        }

        JSONOutput.error("No active IPv4 address found", json: json)
        throw ExitCode.failure
    }
}

struct NetworkInterfaces: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "interfaces", abstract: "List network interfaces")

    @Flag(name: .long) var json = false

    func run() throws {
        let interfaces = discoverInterfaces()
        var payload: [[String: Any]] = []

        for iface in interfaces {
            payload.append([
                "name": iface,
                "active": interfaceIsActive(iface),
                "ip": ipAddress(for: iface) ?? "",
            ])
        }

        if json {
            JSONOutput.printArray(payload, json: true)
        } else {
            for item in payload {
                let name = item["name"] as? String ?? ""
                let active = (item["active"] as? Bool ?? false) ? "active" : "inactive"
                let ip = item["ip"] as? String ?? ""
                if ip.isEmpty {
                    print("\(name) [\(active)]")
                } else {
                    print("\(name) [\(active)] \(ip)")
                }
            }
        }
    }
}
