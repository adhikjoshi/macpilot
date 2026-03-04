import ArgumentParser
import Foundation
import Darwin
import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - State Files

private enum ScreenRecordState {
    static let pidFile = "/tmp/macpilot-screen-record.pid"
    static let pathFile = "/tmp/macpilot-screen-record.path"
    static let startFile = "/tmp/macpilot-screen-record.start"
    static let pausedFile = "/tmp/macpilot-screen-record.paused"
}

private func screenRecordPID() -> pid_t? {
    guard let text = try? String(contentsOfFile: ScreenRecordState.pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = Int32(text), pid > 0 else {
        return nil
    }
    return pid
}

private func isProcessRunning(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func cleanupScreenRecordFiles() {
    try? FileManager.default.removeItem(atPath: ScreenRecordState.pidFile)
    try? FileManager.default.removeItem(atPath: ScreenRecordState.pathFile)
    try? FileManager.default.removeItem(atPath: ScreenRecordState.startFile)
    try? FileManager.default.removeItem(atPath: ScreenRecordState.pausedFile)
}

private func writeScreenRecordState(pid: pid_t, path: String) {
    try? "\(pid)".write(toFile: ScreenRecordState.pidFile, atomically: true, encoding: .utf8)
    try? path.write(toFile: ScreenRecordState.pathFile, atomically: true, encoding: .utf8)
    try? ISO8601DateFormatter().string(from: Date()).write(toFile: ScreenRecordState.startFile, atomically: true, encoding: .utf8)
}

private func readScreenRecordPath() -> String {
    (try? String(contentsOfFile: ScreenRecordState.pathFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
}

private func defaultRecordingPath() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return "/tmp/macpilot_record_\(formatter.string(from: Date())).mov"
}

// MARK: - Screen Command Group

struct Screen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Screen utilities",
        subcommands: [ScreenRecord.self]
    )
}

struct ScreenRecord: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Screen recording",
        subcommands: [
            ScreenRecordStart.self,
            ScreenRecordStop.self,
            ScreenRecordStatus.self,
            ScreenRecordPause.self,
            ScreenRecordResume.self,
        ]
    )
}

// MARK: - screen record start

struct ScreenRecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start screen recording")

    @Option(name: .shortAndLong, help: "Output movie path (.mov)") var output: String?
    @Option(name: .long, help: "Capture region as x,y,w,h") var region: String?
    @Option(name: .long, help: "Capture specific window by name") var window: String?
    @Option(name: .long, help: "Display index (0-based)") var display: Int?
    @Flag(name: .long, help: "Include system audio") var audio = false
    @Option(name: .long, help: "Quality: low, medium, high") var quality: String = "medium"
    @Option(name: .long, help: "Frames per second") var fps: Int = 30
    @Flag(name: .long) var json = false

    func run() throws {
        // Check if daemon mode
        if ProcessInfo.processInfo.environment["MACPILOT_RECORD_DAEMON"] == "1" {
            try runDaemon()
            return
        }

        if let pid = screenRecordPID(), isProcessRunning(pid) {
            JSONOutput.error("Screen recording already running (pid: \(pid))", json: json)
            throw ExitCode.failure
        }

        cleanupScreenRecordFiles()

        var outputPath = output ?? defaultRecordingPath()
        if URL(fileURLWithPath: outputPath).pathExtension.isEmpty {
            outputPath += ".mov"
        }

        flashIndicatorIfRunning()

        // Spawn self as daemon
        let execPath = ProcessInfo.processInfo.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: execPath)
        var args = ["screen", "record", "start", "-o", outputPath, "--quality", quality, "--fps", "\(fps)"]
        if let r = region { args += ["--region", r] }
        if let w = window { args += ["--window", w] }
        if let d = display { args += ["--display", "\(d)"] }
        if audio { args += ["--audio"] }
        task.arguments = args
        task.environment = ProcessInfo.processInfo.environment.merging(["MACPILOT_RECORD_DAEMON": "1"]) { _, new in new }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            JSONOutput.error("Failed to start screen recording: \(error.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        let pid = task.processIdentifier
        writeScreenRecordState(pid: pid, path: outputPath)

        usleep(500_000)
        if !isProcessRunning(pid) {
            cleanupScreenRecordFiles()
            JSONOutput.error("Screen recording failed to start", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Screen recording started",
            "pid": Int(pid),
            "path": outputPath,
            "fps": fps,
            "quality": quality,
        ], json: json)
    }

    private func runDaemon() throws {
        var outputPath = output ?? defaultRecordingPath()
        if URL(fileURLWithPath: outputPath).pathExtension.isEmpty {
            outputPath += ".mov"
        }

        // Set up signal handlers
        signal(SIGUSR1) { _ in
            // Toggle pause state
            let paused = FileManager.default.fileExists(atPath: ScreenRecordState.pausedFile)
            if paused {
                try? FileManager.default.removeItem(atPath: ScreenRecordState.pausedFile)
            } else {
                try? "1".write(toFile: ScreenRecordState.pausedFile, atomically: true, encoding: .utf8)
            }
        }

        signal(SIGTERM) { _ in
            // Will be handled by the SCStream delegate finishing
            CFRunLoopStop(CFRunLoopGetMain())
        }
        signal(SIGINT) { _ in
            CFRunLoopStop(CFRunLoopGetMain())
        }

        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                try await startScreenCaptureKit(outputPath: outputPath)
            } catch {
                // Recording error — daemon will exit
            }
            semaphore.signal()
        }

        // Run the run loop until stopped
        CFRunLoopRun()

        // Give ScreenCaptureKit a moment to finalize
        usleep(500_000)

        // Clean up
        cleanupScreenRecordFiles()
    }

    private func startScreenCaptureKit(outputPath: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Determine what to capture
        var filter: SCContentFilter

        if let regionStr = region {
            // Region capture — capture the display containing the region
            let parts = regionStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { throw MacPilotError.invalidArgument("Region must be x,y,w,h") }

            let targetDisplay = content.displays.first ?? content.displays[0]
            filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        } else if let windowName = window {
            // Window capture
            guard let targetWindow = content.windows.first(where: {
                $0.title?.localizedCaseInsensitiveContains(windowName) == true ||
                $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(windowName) == true
            }) else {
                throw MacPilotError.notFound("Window '\(windowName)' not found")
            }
            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        } else if let displayIndex = display {
            guard displayIndex < content.displays.count else {
                throw MacPilotError.notFound("Display \(displayIndex) not found")
            }
            filter = SCContentFilter(display: content.displays[displayIndex], excludingWindows: [])
        } else {
            // Full screen (primary display)
            let primaryDisplay = content.displays.first!
            filter = SCContentFilter(display: primaryDisplay, excludingWindows: [])
        }

        // Configure stream
        let config = SCStreamConfiguration()

        // Get dimensions — use macOS 14+ APIs if available, fallback to display bounds
        if #available(macOS 14.0, *) {
            config.width = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
            config.height = Int(filter.contentRect.height) * Int(filter.pointPixelScale)
        } else {
            // Fallback: use main screen dimensions
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let scale = Int(screen.backingScaleFactor)
            config.width = Int(screen.frame.width) * scale
            config.height = Int(screen.frame.height) * scale
        }

        let fpsValue = min(max(fps, 1), 60)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fpsValue))

        switch quality {
        case "low":
            config.width = max(config.width / 2, 640)
            config.height = max(config.height / 2, 360)
        case "high":
            break // keep full resolution
        default: // medium
            config.width = max(config.width * 3 / 4, 960)
            config.height = max(config.height * 3 / 4, 540)
        }

        config.showsCursor = true
        if audio {
            config.capturesAudio = true
        }

        // Set up AVAssetWriter
        let outputURL = URL(fileURLWithPath: outputPath)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: qualityBitrate(quality, width: config.width, height: config.height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height,
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            writer.add(ai)
            audioInput = ai
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Create delegate
        let delegate = ScreenCaptureDelegate(
            writer: writer,
            videoInput: videoInput,
            adaptor: adaptor,
            audioInput: audioInput,
            startTime: CMClockGetTime(CMClockGetHostTimeClock())
        )

        // Create and start stream
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if audio {
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await stream.startCapture()

        // Wait for run loop stop (triggered by signal)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                // Poll until run loop stops
                while CFRunLoopIsWaiting(CFRunLoopGetMain()) || true {
                    if !isProcessRunning(getpid()) { break }
                    // Check if we should stop — the run loop has been stopped
                    usleep(200_000)
                    if screenRecordPID() == nil {
                        break
                    }
                }
                continuation.resume()
            }
        }

        // Stop capture
        try await stream.stopCapture()

        // Finalize writer
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
    }

    private func qualityBitrate(_ quality: String, width: Int, height: Int) -> Int {
        let pixels = width * height
        switch quality {
        case "low": return max(pixels / 2, 500_000)
        case "high": return max(pixels * 3, 10_000_000)
        default: return max(pixels, 3_000_000) // medium
        }
    }
}

// MARK: - Screen Capture Delegate

private class ScreenCaptureDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioInput: AVAssetWriterInput?
    let startTime: CMTime

    init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, audioInput: AVAssetWriterInput?, startTime: CMTime) {
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
        self.startTime = startTime
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard writer.status == .writing else { return }

        // Check if paused
        if FileManager.default.fileExists(atPath: ScreenRecordState.pausedFile) { return }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let relativeTime = CMTimeSubtract(timestamp, startTime)

        switch type {
        case .screen:
            guard videoInput.isReadyForMoreMediaData else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
        case .audio:
            guard let ai = audioInput, ai.isReadyForMoreMediaData else { return }
            ai.append(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

private enum MacPilotError: Error, LocalizedError {
    case invalidArgument(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let msg): return msg
        case .notFound(let msg): return msg
        }
    }
}

// MARK: - screen record stop

struct ScreenRecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop screen recording")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = screenRecordPID() else {
            JSONOutput.error("No active screen recording", json: json)
            throw ExitCode.failure
        }

        let outputPath = readScreenRecordPath()

        flashIndicatorIfRunning()
        if isProcessRunning(pid) {
            _ = Darwin.kill(pid, SIGINT)
            let deadline = Date().addingTimeInterval(5.0)
            while isProcessRunning(pid), Date() < deadline {
                usleep(100_000)
            }
            if isProcessRunning(pid) {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }

        cleanupScreenRecordFiles()

        var result: [String: Any] = [
            "status": "ok",
            "message": "Screen recording stopped",
            "path": outputPath,
        ]

        // Check file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let size = attrs[.size] as? UInt64 {
            result["bytes"] = size
        }

        JSONOutput.print(result, json: json)
    }
}

// MARK: - screen record status

struct ScreenRecordStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Check screen recording status")

    @Flag(name: .long) var json = false

    func run() {
        guard let pid = screenRecordPID(), isProcessRunning(pid) else {
            JSONOutput.print([
                "status": "ok",
                "recording": false,
                "message": "No active screen recording",
            ], json: json)
            return
        }

        let path = readScreenRecordPath()
        let paused = FileManager.default.fileExists(atPath: ScreenRecordState.pausedFile)
        let startTime = (try? String(contentsOfFile: ScreenRecordState.startFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        var duration = 0.0
        if let start = ISO8601DateFormatter().date(from: startTime) {
            duration = Date().timeIntervalSince(start)
        }

        var fileSize: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            fileSize = size
        }

        JSONOutput.print([
            "status": "ok",
            "recording": true,
            "paused": paused,
            "pid": Int(pid),
            "path": path,
            "startTime": startTime,
            "duration": Int(duration),
            "bytes": fileSize,
            "message": paused ? "Recording paused (\(Int(duration))s)" : "Recording in progress (\(Int(duration))s)",
        ], json: json)
    }
}

// MARK: - screen record pause

struct ScreenRecordPause: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause screen recording")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = screenRecordPID(), isProcessRunning(pid) else {
            JSONOutput.error("No active screen recording", json: json)
            throw ExitCode.failure
        }

        if FileManager.default.fileExists(atPath: ScreenRecordState.pausedFile) {
            JSONOutput.error("Recording is already paused", json: json)
            throw ExitCode.failure
        }

        // Send SIGUSR1 to toggle pause
        _ = Darwin.kill(pid, SIGUSR1)
        usleep(100_000)

        JSONOutput.print([
            "status": "ok",
            "message": "Screen recording paused",
            "pid": Int(pid),
        ], json: json)
    }
}

// MARK: - screen record resume

struct ScreenRecordResume: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume screen recording")

    @Flag(name: .long) var json = false

    func run() throws {
        guard let pid = screenRecordPID(), isProcessRunning(pid) else {
            JSONOutput.error("No active screen recording", json: json)
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: ScreenRecordState.pausedFile) else {
            JSONOutput.error("Recording is not paused", json: json)
            throw ExitCode.failure
        }

        // Send SIGUSR1 to toggle pause
        _ = Darwin.kill(pid, SIGUSR1)
        usleep(100_000)

        JSONOutput.print([
            "status": "ok",
            "message": "Screen recording resumed",
            "pid": Int(pid),
        ], json: json)
    }
}
