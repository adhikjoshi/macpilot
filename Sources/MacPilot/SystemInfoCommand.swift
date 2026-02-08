import ArgumentParser
import AppKit
import Foundation
import Darwin

private func sysctlStringValue(_ key: String) -> String? {
    var size: size_t = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

private func bytesToGiB(_ bytes: UInt64) -> Double {
    Double(bytes) / (1024.0 * 1024.0 * 1024.0)
}

struct SystemCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "System information",
        subcommands: [SystemInfo.self]
    )
}

struct SystemInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show system information")

    @Flag(name: .long) var json = false

    func run() throws {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion

        let cpuBrand = sysctlStringValue("machdep.cpu.brand_string") ?? ""
        let cpuCores = processInfo.activeProcessorCount
        let cpuLogical = processInfo.processorCount
        let memoryBytes = processInfo.physicalMemory

        let fsAttributes = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
        let diskTotal = (fsAttributes[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let diskFree = (fsAttributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0

        let displays: [[String: Any]] = NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return [
                "index": index,
                "width": Int(frame.width),
                "height": Int(frame.height),
                "scale": scale,
            ]
        }

        let payload: [String: Any] = [
            "status": "ok",
            "hostname": Host.current().localizedName ?? "",
            "os": [
                "version": processInfo.operatingSystemVersionString,
                "major": osVersion.majorVersion,
                "minor": osVersion.minorVersion,
                "patch": osVersion.patchVersion,
            ],
            "cpu": [
                "brand": cpuBrand,
                "activeCores": cpuCores,
                "logicalCores": cpuLogical,
            ],
            "memory": [
                "bytes": memoryBytes,
                "gib": bytesToGiB(memoryBytes),
            ],
            "disk": [
                "totalBytes": diskTotal,
                "freeBytes": diskFree,
                "totalGiB": bytesToGiB(diskTotal),
                "freeGiB": bytesToGiB(diskFree),
            ],
            "displays": displays,
            "message": "Collected system information",
        ]

        if json {
            JSONOutput.print(payload, json: true)
            return
        }

        print("OS: \(processInfo.operatingSystemVersionString)")
        print("CPU: \(cpuBrand) (\(cpuCores) active / \(cpuLogical) logical)")
        print(String(format: "Memory: %.2f GiB", bytesToGiB(memoryBytes)))
        print(String(format: "Disk: %.2f GiB free / %.2f GiB total", bytesToGiB(diskFree), bytesToGiB(diskTotal)))
        print("Displays: \(displays.count)")
    }
}
