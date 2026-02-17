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

private func imageDimensions(path: String) -> (width: CGFloat, height: CGFloat) {
    guard let image = NSImage(contentsOfFile: path), let rep = image.representations.first else {
        return (0, 0)
    }
    return (CGFloat(rep.pixelsWide), CGFloat(rep.pixelsHigh))
}

struct OCR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Extract text from an image or screen region"
    )

    @Argument(parsing: .remaining, help: "Either <image-path> or <x> <y> <w> <h>")
    var input: [String] = []

    @Option(name: .long, help: "Recognition language (e.g. en-US, ja, zh-Hans, de, fr)") var language: String?
    @Flag(name: .long) var json = false

    func run() throws {
        guard input.count == 1 || input.count == 4 else {
            JSONOutput.error("Usage: ocr <image-path> OR ocr <x> <y> <w> <h>", json: json)
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

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        if let lang = language {
            request.recognitionLanguages = [lang]
        } else {
            request.recognitionLanguages = ["en-US"]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            JSONOutput.error("OCR failed: \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        let dimensions = imageDimensions(path: imagePath)
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        let observations = request.results ?? []

        var lines: [[String: Any]] = []
        var fullText: [String] = []

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let rect = obs.boundingBox
            // Image pixel coordinates
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

        flashIndicatorIfRunning()

        if json {
            let result: [String: Any] = [
                "status": "ok",
                "path": imagePath,
                "text": fullText.joined(separator: "\n"),
                "lines": lines,
                "scaleFactor": scaleFactor,
                "regionOffset": ["x": regionOffsetX, "y": regionOffsetY],
            ]
            JSONOutput.print(result, json: true)
        } else {
            if fullText.isEmpty {
                print("")
            } else {
                print(fullText.joined(separator: "\n"))
            }
        }
    }
}
