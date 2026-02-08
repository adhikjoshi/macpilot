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

    @Flag(name: .long) var json = false

    func run() throws {
        guard input.count == 1 || input.count == 4 else {
            JSONOutput.error("Usage: ocr <image-path> OR ocr <x> <y> <w> <h>", json: json)
            throw ExitCode.failure
        }

        var imagePath = ""
        var tempFileToDelete: String?

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
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            JSONOutput.error("OCR failed: \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        let dimensions = imageDimensions(path: imagePath)
        let observations = request.results ?? []

        var lines: [[String: Any]] = []
        var fullText: [String] = []

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let rect = obs.boundingBox
            let x = rect.origin.x * dimensions.width
            let y = (1.0 - rect.origin.y - rect.size.height) * dimensions.height
            let width = rect.size.width * dimensions.width
            let height = rect.size.height * dimensions.height

            let text = candidate.string
            fullText.append(text)
            lines.append([
                "text": text,
                "confidence": candidate.confidence,
                "x": Int(round(x)),
                "y": Int(round(y)),
                "width": Int(round(width)),
                "height": Int(round(height)),
            ])
        }

        flashIndicatorIfRunning()

        if json {
            JSONOutput.print([
                "status": "ok",
                "path": imagePath,
                "text": fullText.joined(separator: "\n"),
                "lines": lines,
            ], json: true)
        } else {
            if fullText.isEmpty {
                print("")
            } else {
                print(fullText.joined(separator: "\n"))
            }
        }
    }
}
