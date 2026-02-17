import ArgumentParser
import AppKit
import Foundation

// MARK: - Gap E: Multi-display coordinate awareness

struct DisplayInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display-info",
        abstract: "List all displays with positions, sizes, and scale factors"
    )

    @Flag(name: .long) var json = false

    func run() throws {
        var results: [[String: Any]] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            let visible = screen.visibleFrame
            var info: [String: Any] = [
                "index": i,
                "name": screen.localizedName,
                "x": Int(frame.origin.x),
                "y": Int(frame.origin.y),
                "width": Int(frame.size.width),
                "height": Int(frame.size.height),
                "visibleX": Int(visible.origin.x),
                "visibleY": Int(visible.origin.y),
                "visibleWidth": Int(visible.size.width),
                "visibleHeight": Int(visible.size.height),
                "scaleFactor": screen.backingScaleFactor,
                "main": screen == NSScreen.main,
            ]
            // Pixel dimensions (Retina)
            info["pixelWidth"] = Int(frame.size.width * screen.backingScaleFactor)
            info["pixelHeight"] = Int(frame.size.height * screen.backingScaleFactor)
            results.append(info)
        }

        if json {
            JSONOutput.printArray(results, json: true)
        } else {
            for d in results {
                let idx = d["index"] as? Int ?? 0
                let name = d["name"] as? String ?? "Display \(idx)"
                let w = d["width"] as? Int ?? 0
                let h = d["height"] as? Int ?? 0
                let x = d["x"] as? Int ?? 0
                let y = d["y"] as? Int ?? 0
                let scale = d["scaleFactor"] as? CGFloat ?? 1.0
                let main = (d["main"] as? Bool ?? false) ? " (main)" : ""
                let pw = d["pixelWidth"] as? Int ?? 0
                let ph = d["pixelHeight"] as? Int ?? 0
                print("Display \(idx): \(name) \(w)x\(h) at (\(x),\(y)) scale=\(scale)x pixels=\(pw)x\(ph)\(main)")
            }
        }
    }
}
