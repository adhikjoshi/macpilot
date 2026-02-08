import ArgumentParser
import CoreGraphics
import Foundation
import AppKit
import ImageIO

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Take a screenshot")

    @Argument(help: "Output file path (positional alias for --output)") var outputPositional: String?
    @Option(name: .long, help: "Region as x,y,width,height") var region: String?
    @Option(name: .long, help: "Window name to capture") var window: String?
    @Option(name: .shortAndLong, help: "Output file path") var output: String?
    @Option(name: .long, help: "Output format: png or jpg") var format: String?
    @Flag(name: .long, help: "Capture ALL windows including other Spaces") var allWindows = false
    @Option(name: .long, help: "Display index (0-based)") var display: UInt32?
    @Flag(name: .long) var json = false

    func run() throws {
        let resolvedFormat = try resolveFormat()
        let outputPath = resolvedOutputPath(format: resolvedFormat)
        flashIndicatorIfRunning()

        if allWindows {
            try captureAllWindowsViaCG(outputPath: outputPath, format: resolvedFormat)
            return
        }

        let commandResult = try runScreencapture(outputPath: outputPath, format: resolvedFormat)
        if commandResult.exitCode != 0 {
            let reason = commandResult.stderr.isEmpty ? "Failed to capture screenshot" : commandResult.stderr
            JSONOutput.error(reason, json: json)
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            JSONOutput.error("Screenshot command succeeded but output file is missing", json: json)
            throw ExitCode.failure
        }

        try printCaptureResult(outputPath: outputPath)
    }

    private func resolveFormat() throws -> String {
        let ext = URL(fileURLWithPath: output ?? outputPositional ?? "").pathExtension.lowercased()
        let candidate = (format ?? ext).lowercased()
        if candidate.isEmpty { return "png" }
        if candidate == "jpeg" { return "jpg" }
        guard candidate == "png" || candidate == "jpg" else {
            JSONOutput.error("Format must be png or jpg", json: json)
            throw ExitCode.failure
        }
        return candidate
    }

    private func resolvedOutputPath(format: String) -> String {
        let base = output ?? outputPositional ?? "/tmp/macpilot_screenshot.\(format)"
        let ext = URL(fileURLWithPath: base).pathExtension
        guard ext.isEmpty else { return base }
        return "\(base).\(format)"
    }

    private func runScreencapture(outputPath: String, format: String) throws -> (exitCode: Int32, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        var args = ["-x", "-t", format]
        if let region = region {
            let parts = region.split(separator: ",").compactMap { Int(Double($0.trimmingCharacters(in: .whitespaces)) ?? -1) }
            guard parts.count == 4 else {
                JSONOutput.error("Region must be x,y,width,height", json: json)
                throw ExitCode.failure
            }
            args.append("-R\(parts[0]),\(parts[1]),\(parts[2]),\(parts[3])")
        } else if let windowName = window {
            guard let windowID = windowID(named: windowName) else {
                JSONOutput.error("Window not found: \(windowName)", json: json)
                throw ExitCode.failure
            }
            args.append("-l")
            args.append(String(windowID))
        } else if let displayIndex = display {
            args.append("-D")
            args.append(String(displayIndex + 1))
        }

        args.append(outputPath)
        task.arguments = args

        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, stderr)
    }

    private func captureAllWindowsViaCG(outputPath: String, format: String) throws {
        let image = CGWindowListCreateImage(.null, .optionAll, kCGNullWindowID, .bestResolution)
        guard let cgImage = image else {
            JSONOutput.error("Failed to capture screenshot", json: json)
            throw ExitCode.failure
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let fileType: NSBitmapImageRep.FileType = format == "jpg" ? .jpeg : .png
        guard let data = bitmap.representation(using: fileType, properties: [:]) else {
            JSONOutput.error("Failed to encode screenshot", json: json)
            throw ExitCode.failure
        }
        try data.write(to: URL(fileURLWithPath: outputPath))
        try printCaptureResult(outputPath: outputPath)
    }

    private func printCaptureResult(outputPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let (width, height) = imageSize(from: data)

        if json {
            JSONOutput.print([
                "status": "ok",
                "path": outputPath,
                "width": width,
                "height": height,
                "bytes": data.count,
            ], json: true)
        } else {
            print("Screenshot saved to \(outputPath) (\(width)x\(height))")
        }
    }

    private func imageSize(from data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    private func windowID(named name: String) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for win in windowList {
            if let ownerName = win[kCGWindowOwnerName as String] as? String,
               ownerName.localizedCaseInsensitiveContains(name),
               let windowID = win[kCGWindowNumber as String] as? CGWindowID {
                return windowID
            }
        }
        return nil
    }
}
