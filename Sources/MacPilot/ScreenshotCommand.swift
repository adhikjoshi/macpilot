import ArgumentParser
import CoreGraphics
import Foundation
import AppKit

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Take a screenshot")

    @Option(name: .long, help: "Region as x,y,width,height") var region: String?
    @Option(name: .long, help: "Window name to capture") var window: String?
    @Option(name: .shortAndLong, help: "Output file path") var output: String?
    @Flag(name: .long) var json = false

    func run() throws {
        let image: CGImage?

        if let region = region {
            let parts = region.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                JSONOutput.error("Region must be x,y,width,height", json: json)
                throw ExitCode.failure
            }
            let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        } else if let windowName = window {
            image = captureWindow(named: windowName)
        } else {
            image = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        }

        guard let cgImage = image else {
            JSONOutput.error("Failed to capture screenshot", json: json)
            throw ExitCode.failure
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            JSONOutput.error("Failed to encode PNG", json: json)
            throw ExitCode.failure
        }

        let outputPath: String
        if let out = output {
            outputPath = out
        } else {
            outputPath = "/tmp/macpilot_screenshot.png"
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))

        if json {
            JSONOutput.print([
                "status": "ok",
                "path": outputPath,
                "width": cgImage.width,
                "height": cgImage.height,
                "bytes": pngData.count,
            ], json: true)
        } else {
            print("Screenshot saved to \(outputPath) (\(cgImage.width)x\(cgImage.height))")
        }
    }

    private func captureWindow(named name: String) -> CGImage? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for win in windowList {
            if let ownerName = win[kCGWindowOwnerName as String] as? String,
               ownerName.localizedCaseInsensitiveContains(name),
               let windowID = win[kCGWindowNumber as String] as? CGWindowID {
                let bounds = win[kCGWindowBounds as String] as? [String: Any]
                if let b = bounds,
                   let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                   let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat {
                    let rect = CGRect(x: x, y: y, width: w, height: h)
                    return CGWindowListCreateImage(rect, .optionIncludingWindow, windowID, .bestResolution)
                }
            }
        }
        return nil
    }
}
