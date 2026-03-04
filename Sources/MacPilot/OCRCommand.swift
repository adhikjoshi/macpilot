import ArgumentParser
import AppKit
import Foundation
import Vision

private func captureRegionToImage(x: Int, y: Int, width: Int, height: Int, outputPath: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-R\(x),\(y),\(width),\(height)", outputPath]

    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputPath)
    } catch {
        return false
    }
}

private func captureFullScreen(outputPath: String) -> Bool {
    guard let image = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else {
        return false
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
        return true
    } catch {
        return false
    }
}

private func imageDimensions(path: String) -> (width: CGFloat, height: CGFloat) {
    guard let image = NSImage(contentsOfFile: path), let rep = image.representations.first else {
        return (0, 0)
    }
    return (CGFloat(rep.pixelsWide), CGFloat(rep.pixelsHigh))
}

/// Run OCR on a CGImage and return observations with screen coordinates
private func runOCR(
    cgImage: CGImage,
    imagePath: String,
    regionOffsetX: Int = 0,
    regionOffsetY: Int = 0,
    language: String?
) -> (text: [String], lines: [[String: Any]])? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [language ?? "en-US"]

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return nil
    }

    let dimensions = imageDimensions(path: imagePath)
    let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
    let observations = request.results ?? []

    var lines: [[String: Any]] = []
    var fullText: [String] = []

    for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        let rect = obs.boundingBox
        let imgX = rect.origin.x * dimensions.width
        let imgY = (1.0 - rect.origin.y - rect.size.height) * dimensions.height
        let imgW = rect.size.width * dimensions.width
        let imgH = rect.size.height * dimensions.height

        let screenX = Int(round(imgX / scaleFactor)) + regionOffsetX
        let screenY = Int(round(imgY / scaleFactor)) + regionOffsetY
        let screenW = Int(round(imgW / scaleFactor))
        let screenH = Int(round(imgH / scaleFactor))

        let text = candidate.string
        fullText.append(text)
        let lineInfo: [String: Any] = [
            "text": text,
            "confidence": candidate.confidence,
            "x": Int(round(imgX)),
            "y": Int(round(imgY)),
            "width": Int(round(imgW)),
            "height": Int(round(imgH)),
            "screenX": screenX,
            "screenY": screenY,
            "screenWidth": screenW,
            "screenHeight": screenH,
            "screenCenterX": screenX + screenW / 2,
            "screenCenterY": screenY + screenH / 2,
        ]
        lines.append(lineInfo)
    }

    return (fullText, lines)
}

// MARK: - Command Group

struct OCR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "OCR text recognition and visual text interaction",
        subcommands: [OCRScan.self, OCRClick.self],
        defaultSubcommand: OCRScan.self
    )
}

// MARK: - ocr scan (existing behavior)

struct OCRScan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Extract text from an image or screen region"
    )

    @Argument(parsing: .remaining, help: "Either <image-path> or <x> <y> <w> <h>")
    var input: [String] = []

    @Option(name: .long, help: "Recognition language (e.g. en-US, ja, zh-Hans, de, fr)") var language: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard input.count == 1 || input.count == 4 else {
            JSONOutput.error("Usage: ocr scan <image-path> OR ocr scan <x> <y> <w> <h>", json: json)
            throw ExitCode.failure
        }

        var imagePath = ""
        var tempFileToDelete: String?
        var regionOffsetX = 0
        var regionOffsetY = 0

        if input.count == 1 {
            imagePath = input[0]
            guard FileManager.default.fileExists(atPath: imagePath) else {
                JSONOutput.error("Image not found: \(imagePath)", json: json)
                throw ExitCode.failure
            }
        } else {
            guard let x = Int(input[0]), let y = Int(input[1]), let w = Int(input[2]), let h = Int(input[3]),
                  w > 0, h > 0 else {
                JSONOutput.error("Region must be integer x y w h with positive size", json: json)
                throw ExitCode.failure
            }

            regionOffsetX = x
            regionOffsetY = y

            let tmp = "/tmp/macpilot_ocr_\(UUID().uuidString).png"
            guard captureRegionToImage(x: x, y: y, width: w, height: h, outputPath: tmp) else {
                JSONOutput.error("Failed to capture region for OCR", json: json)
                throw ExitCode.failure
            }
            imagePath = tmp
            tempFileToDelete = tmp
        }

        defer {
            if let tmp = tempFileToDelete {
                try? FileManager.default.removeItem(atPath: tmp)
            }
        }

        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            JSONOutput.error("Failed to decode image for OCR", json: json)
            throw ExitCode.failure
        }

        guard let result = runOCR(cgImage: cgImage, imagePath: imagePath,
                                   regionOffsetX: regionOffsetX, regionOffsetY: regionOffsetY,
                                   language: language) else {
            JSONOutput.error("OCR failed", json: json)
            throw ExitCode.failure
        }

        flashIndicatorIfRunning()

        if json {
            let output: [String: Any] = [
                "status": "ok",
                "path": imagePath,
                "text": result.text.joined(separator: "\n"),
                "lines": result.lines,
                "scaleFactor": NSScreen.main?.backingScaleFactor ?? 1.0,
                "regionOffset": ["x": regionOffsetX, "y": regionOffsetY],
            ]
            JSONOutput.print(output, json: true)
        } else {
            if result.text.isEmpty {
                print("")
            } else {
                print(result.text.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - ocr click (NEW)

struct OCRClick: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Find text on screen via OCR and click it"
    )

    @Argument(help: "Text to find and click") var text: String
    @Option(name: .long, help: "Focus app by name before scanning") var app: String?
    @Option(name: .long, help: "Timeout in seconds to retry until text appears") var timeout: Double = 0
    @Option(name: .long, help: "Recognition language") var language: String?
    @Flag(name: .long) var json = false

    func run() throws {
        // Focus app if specified
        if let appName = app {
            sharedRunAppleScript("tell application \"\(appName)\" to activate")
            usleep(500_000)
        }

        flashIndicatorIfRunning()

        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        let lowerText = text.lowercased()

        while true {
            // Capture full screen
            let tmpPath = "/tmp/macpilot_ocr_click_\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }

            guard captureFullScreen(outputPath: tmpPath),
                  let image = NSImage(contentsOfFile: tmpPath),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                if Date() >= deadline {
                    JSONOutput.error("Failed to capture screen for OCR", json: json)
                    throw ExitCode.failure
                }
                usleep(500_000)
                continue
            }

            guard let result = runOCR(cgImage: cgImage, imagePath: tmpPath, language: language) else {
                if Date() >= deadline {
                    JSONOutput.error("OCR failed", json: json)
                    throw ExitCode.failure
                }
                usleep(500_000)
                continue
            }

            // Find matching line (case-insensitive contains)
            if let match = result.lines.first(where: {
                ($0["text"] as? String)?.lowercased().contains(lowerText) == true
            }) {
                let cx = match["screenCenterX"] as? Int ?? 0
                let cy = match["screenCenterY"] as? Int ?? 0

                // Click at center
                let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)
                moveEvent?.post(tap: .cghidEventTap)
                usleep(50_000)

                let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)
                downEvent?.post(tap: .cghidEventTap)
                usleep(30_000)

                let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                      mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)
                upEvent?.post(tap: .cghidEventTap)

                JSONOutput.print([
                    "status": "ok",
                    "message": "Clicked '\(text)' at (\(cx), \(cy))",
                    "matchedText": match["text"] as? String ?? "",
                    "x": cx,
                    "y": cy,
                    "confidence": match["confidence"] as? Float ?? 0,
                ], json: json)
                return
            }

            // Not found — retry if within timeout
            if Date() >= deadline {
                JSONOutput.error("Text '\(text)' not found on screen", json: json)
                throw ExitCode.failure
            }
            usleep(500_000)
        }
    }
}
