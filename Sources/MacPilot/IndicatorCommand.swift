import ApplicationServices
import ArgumentParser
import AppKit
import CoreGraphics
import Darwin
import Foundation

enum IndicatorPaths {
    static let socket = "/tmp/macpilot-indicator.sock"
    static let pid = "/tmp/macpilot-indicator.pid"
    static let active = "/tmp/macpilot-indicator-active"
}

enum IndicatorIPCCommand: String {
    case flash
    case stop
    case ping
}

enum IndicatorClient {
    static func runningPID() -> pid_t? {
        guard let raw = try? String(contentsOfFile: IndicatorPaths.pid, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(raw), pid > 0 else {
            return nil
        }
        return pid
    }

    static func isRunning() -> Bool {
        guard let pid = runningPID() else {
            return FileManager.default.fileExists(atPath: IndicatorPaths.active)
        }

        if Darwin.kill(pid, 0) == 0 || errno == EPERM {
            return true
        }

        removeStateFiles()
        return false
    }

    @discardableResult
    static func send(_ command: IndicatorIPCCommand) -> Bool {
        let fd = connectSocket()
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        let payload = "\(command.rawValue)\n"
        let writeOK = payload.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr)) > 0
        }
        guard writeOK else { return false }

        var buffer = [UInt8](repeating: 0, count: 64)
        let readBytes = Darwin.read(fd, &buffer, buffer.count)
        guard readBytes > 0 else { return false }
        let response = String(decoding: buffer.prefix(readBytes), as: UTF8.self)
        return response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
    }

    static func flashIfRunning() {
        flashForAction()
    }

    static func flashForAction() {
        IndicatorAutoStarter.ensureRunningIfNeeded()
        guard isRunning() else { return }
        _ = send(.flash)
        sendActivity()
    }

    @discardableResult
    static func sendRaw(_ message: String) -> Bool {
        let fd = connectSocket()
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        let payload = "\(message)\n"
        let writeOK = payload.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr)) > 0
        }
        guard writeOK else { return false }

        var buffer = [UInt8](repeating: 0, count: 64)
        let readBytes = Darwin.read(fd, &buffer, buffer.count)
        guard readBytes > 0 else { return false }
        let response = String(decoding: buffer.prefix(readBytes), as: UTF8.self)
        return response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
    }

    static func sendActivity() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { return }
        let commandName = args.filter { !$0.hasPrefix("-") }.prefix(3).joined(separator: " ")
        guard !commandName.isEmpty else { return }
        _ = sendRaw("activity:\(commandName)")
    }

    static func removeStateFiles() {
        try? FileManager.default.removeItem(atPath: IndicatorPaths.pid)
        try? FileManager.default.removeItem(atPath: IndicatorPaths.active)
    }

    private static func connectSocket() -> Int32 {
        guard FileManager.default.fileExists(atPath: IndicatorPaths.socket) else { return -1 }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var address = makeSocketAddress(path: IndicatorPaths.socket)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            _ = Darwin.close(fd)
            return -1
        }

        return fd
    }

    static func makeSocketAddress(path: String) -> sockaddr_un {
        var address = sockaddr_un()
#if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            let count = min(pathBytes.count, rawBuffer.count - 1)
            rawBuffer.copyBytes(from: pathBytes.prefix(count))
        }
        return address
    }
}

private enum IndicatorAutoStarter {
    static let skipEnvironmentKey = "MACPILOT_SKIP_INDICATOR_AUTOSTART"

    static func ensureRunningIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard shouldAutoStart(arguments: arguments) else { return }
        guard !IndicatorClient.isRunning() else { return }
        guard launchIndicatorProcess() else { return }

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if IndicatorClient.isRunning() {
                return
            }
            usleep(50_000)
        }
    }

    private static func shouldAutoStart(arguments: [String]) -> Bool {
        if ProcessInfo.processInfo.environment[skipEnvironmentKey] == "1" {
            return false
        }

        guard arguments.count > 1 else { return false }
        let args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") || args.contains("--version") {
            return false
        }

        if args.first?.lowercased() == "help" {
            return false
        }

        if let firstCommand = args.first(where: { !$0.hasPrefix("-") })?.lowercased(),
           firstCommand == "indicator" {
            return false
        }

        return true
    }

    private static func launchIndicatorProcess() -> Bool {
        guard let executablePath = resolveExecutablePath() else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = ["indicator", "start"]

        var environment = ProcessInfo.processInfo.environment
        environment[skipEnvironmentKey] = "1"
        task.environment = environment

        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        task.standardOutput = devNull
        task.standardError = devNull

        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }

    private static func resolveExecutablePath() -> String? {
        if let bundleExecutable = Bundle.main.executablePath,
           FileManager.default.isExecutableFile(atPath: bundleExecutable) {
            return bundleExecutable
        }

        guard let arg0 = CommandLine.arguments.first, !arg0.isEmpty else { return nil }
        if arg0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: arg0) {
            return arg0
        }

        if arg0.contains("/") {
            let absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0)
                .standardized
                .path
            if FileManager.default.isExecutableFile(atPath: absolute) {
                return absolute
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [arg0]

        let outPipe = Pipe()
        task.standardOutput = outPipe

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
        } catch {
            return nil
        }

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else { return nil }
        return output
    }
}

func ensureIndicatorAutoStartIfNeeded() {
    IndicatorAutoStarter.ensureRunningIfNeeded()
}

func flashIndicatorIfRunning() {
    IndicatorClient.flashForAction()
}

func sendActivityToIndicator() {
    if IndicatorClient.isRunning() {
        IndicatorClient.sendActivity()
    }
}

private var indicatorServerController: IndicatorServerController?

private struct ActivityEntry {
    let command: String
    let timestamp: Date
}

private enum IndicatorSettingsURL {
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let automation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

private final class IndicatorServerController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [NSWindow] = []
    private var borderViews: [IndicatorBorderView] = []
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var pulseTimer: Timer?
    private var pulsePhase = false

    // Menu bar
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var iconPhase = false

    // Activity tracking
    private var recentActivities: [ActivityEntry] = []
    private let maxActivities = 10
    private let activityLock = NSLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeStateFiles()
        buildOverlayWindows()
        startPulseAnimation()
        startIPCServer()
        setupMenuBar()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    @objc private func handleScreenChange() {
        buildOverlayWindows()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        button.toolTip = "MacPilot"
        updateMenuBarIcon()

        menu.delegate = self
        statusItem?.menu = menu
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        iconPhase.toggle()
        let symbolName = iconPhase ? "command.circle.fill" : "command.circle"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacPilot") {
            image.isTemplate = false
            button.image = image
            button.contentTintColor = NSColor.systemTeal
        } else {
            button.title = "MP"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Header
        let header = NSMenuItem(title: "MacPilot v0.6.0", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let attrTitle = NSAttributedString(string: "MacPilot v0.6.0", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
        ])
        header.attributedTitle = attrTitle
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Recent Activity
        let activityHeader = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        activityHeader.isEnabled = false
        menu.addItem(activityHeader)

        activityLock.lock()
        let activities = recentActivities
        activityLock.unlock()

        if activities.isEmpty {
            let emptyItem = NSMenuItem(title: "  No recent activity", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let now = Date()
            for (index, entry) in activities.enumerated() {
                let age = now.timeIntervalSince(entry.timestamp)
                let ageStr = formatAge(age)
                let bullet = index == 0 ? "\u{25CF}" : "\u{25CB}"
                let item = NSMenuItem(
                    title: "  \(bullet) \(entry.command)  (\(ageStr))",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Permissions
        let permHeader = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permHeader.isEnabled = false
        menu.addItem(permHeader)

        addPermissionItem("Accessibility", granted: checkAccessibility(), settingsURL: IndicatorSettingsURL.accessibility)
        addPermissionItem("Screen Recording", granted: checkScreenRecording(), settingsURL: IndicatorSettingsURL.screenRecording)
        addPermissionItem("Full Disk Access", granted: checkFullDiskAccess(), settingsURL: IndicatorSettingsURL.fullDiskAccess)
        addPermissionItem("Automation", granted: checkAutomation(), settingsURL: IndicatorSettingsURL.automation)

        menu.addItem(NSMenuItem.separator())

        let openAll = NSMenuItem(title: "Open All Permission Settings", action: #selector(openAllPermissions), keyEquivalent: "")
        openAll.target = self
        menu.addItem(openAll)

        menu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop Indicator", action: #selector(stopIndicator), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        let quitItem = NSMenuItem(title: "Quit MacPilot", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addPermissionItem(_ name: String, granted: Bool, settingsURL: String) {
        let marker = granted ? "\u{2705}" : "\u{274C}"
        let title = "  \(marker) \(name)"

        if granted {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "\(title)  \u{2192} Open", action: #selector(openPermissionSettings(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = settingsURL
            menu.addItem(item)
        }
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    // MARK: - Menu Actions

    @objc private func openPermissionSettings(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        openSettingsPane(urlString)
    }

    @objc private func openAllPermissions() {
        openSettingsPane(IndicatorSettingsURL.accessibility)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.openSettingsPane(IndicatorSettingsURL.screenRecording)
        }
    }

    @objc private func stopIndicator() {
        NSApp.terminate(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if NSWorkspace.shared.open(url) { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [urlString]
        try? task.run()
    }

    // MARK: - Permission Checks

    private func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    private func checkScreenRecording() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    private func checkFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let mailPath = NSString(string: "~/Library/Mail").expandingTildeInPath
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"

        var isDir = ObjCBool(false)
        if fm.fileExists(atPath: mailPath, isDirectory: &isDir), isDir.boolValue,
           (try? fm.contentsOfDirectory(atPath: mailPath)) != nil {
            return true
        }
        if (try? Data(contentsOf: URL(fileURLWithPath: tccPath), options: .mappedIfSafe)) != nil {
            return true
        }
        return false
    }

    private func checkAutomation() -> Bool {
        let source = "tell application \"System Events\" to count (every process)"
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    // MARK: - Activity Tracking

    private func recordActivity(_ command: String) {
        activityLock.lock()
        recentActivities.insert(ActivityEntry(command: command, timestamp: Date()), at: 0)
        if recentActivities.count > maxActivities {
            recentActivities.removeLast()
        }
        activityLock.unlock()
    }

    // MARK: - State Files

    private func writeStateFiles() {
        let pidString = "\(ProcessInfo.processInfo.processIdentifier)"
        try? pidString.write(toFile: IndicatorPaths.pid, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: IndicatorPaths.active, contents: Data())
    }

    private func cleanup() {
        pulseTimer?.invalidate()
        pulseTimer = nil

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        listenerSource?.cancel()
        listenerSource = nil

        if listenerFD >= 0 {
            _ = Darwin.close(listenerFD)
            listenerFD = -1
        }

        try? FileManager.default.removeItem(atPath: IndicatorPaths.socket)
        IndicatorClient.removeStateFiles()
    }

    // MARK: - Overlay Windows

    private func buildOverlayWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
        borderViews.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let view = IndicatorBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            borderViews.append(view)
        }
    }

    private func startPulseAnimation() {
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase.toggle()
            let level: CGFloat = self.pulsePhase ? 0.15 : 0.0
            self.borderViews.forEach { $0.setAmbientPulse(level) }
            self.updateMenuBarIcon()
        }
    }

    // MARK: - IPC Server

    private func startIPCServer() {
        try? FileManager.default.removeItem(atPath: IndicatorPaths.socket)

        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { return }

        _ = fcntl(listenerFD, F_SETFL, O_NONBLOCK)

        var address = IndicatorClient.makeSocketAddress(path: IndicatorPaths.socket)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            _ = Darwin.close(listenerFD)
            listenerFD = -1
            return
        }

        guard Darwin.listen(listenerFD, 8) == 0 else {
            _ = Darwin.close(listenerFD)
            listenerFD = -1
            return
        }

        listenerSource = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: DispatchQueue.global(qos: .userInitiated))
        listenerSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        listenerSource?.setCancelHandler { [weak self] in
            if let fd = self?.listenerFD, fd >= 0 {
                _ = Darwin.close(fd)
                self?.listenerFD = -1
            }
        }
        listenerSource?.resume()
    }

    private func acceptConnections() {
        while true {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            handleClient(clientFD)
            _ = Darwin.close(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let readBytes = Darwin.read(clientFD, &buffer, buffer.count)
        guard readBytes > 0 else {
            _ = writeResponse("error\n", to: clientFD)
            return
        }

        let raw = String(decoding: buffer.prefix(readBytes), as: UTF8.self)
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandLower = command.lowercased()

        // Handle activity:command_name format
        if commandLower.hasPrefix("activity:") {
            let activityName = String(command.dropFirst("activity:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !activityName.isEmpty {
                recordActivity(activityName)
            }
            _ = writeResponse("ok\n", to: clientFD)
            return
        }

        switch commandLower {
        case IndicatorIPCCommand.flash.rawValue:
            DispatchQueue.main.async { [weak self] in
                self?.borderViews.forEach { $0.flash(duration: 0.2) }
            }
            _ = writeResponse("ok\n", to: clientFD)
        case IndicatorIPCCommand.stop.rawValue:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            _ = writeResponse("ok\n", to: clientFD)
        case IndicatorIPCCommand.ping.rawValue:
            _ = writeResponse("ok\n", to: clientFD)
        default:
            _ = writeResponse("error\n", to: clientFD)
        }
    }

    private func writeResponse(_ response: String, to fd: Int32) -> Bool {
        response.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr)) > 0
        }
    }
}

private final class IndicatorBorderView: NSView {
    private var flashLevel: CGFloat = 0.0 {
        didSet { needsDisplay = true }
    }
    private var ambientLevel: CGFloat = 0.0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    func setAmbientPulse(_ level: CGFloat) {
        ambientLevel = min(max(level, 0.0), 0.25)
    }

    func flash(duration: TimeInterval) {
        flashLevel = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.flashLevel = 0.0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let emphasis = max(flashLevel, ambientLevel)
        let lineWidth: CGFloat = 4.0 + (2.0 * emphasis)
        let inset = lineWidth / 2.0 + 1.0
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let color = NSColor.systemCyan.withAlphaComponent(0.42 + (0.38 * emphasis))
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 12.0 + (10.0 * emphasis)
        shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.33 + (0.35 * emphasis))

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private enum StandaloneIndicatorFlash {
    static func show(duration: TimeInterval) {
        let windows = NSScreen.screens.map { screen -> NSWindow in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let view = IndicatorBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.flash(duration: duration)
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }

        let until = Date().addingTimeInterval(duration + 0.1)
        RunLoop.current.run(until: until)
        windows.forEach { $0.close() }
    }
}

struct Indicator: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "indicator",
        abstract: "Visual activity indicator overlay",
        subcommands: [IndicatorStart.self, IndicatorStop.self, IndicatorFlash.self, IndicatorStatus.self]
    )
}

struct IndicatorStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start persistent edge indicator overlay")

    @Flag(name: .long) var json = false

    func run() throws {
        if IndicatorClient.isRunning() {
            JSONOutput.print([
                "status": "ok",
                "message": "Indicator already running",
                "running": true,
                "pid": Int(IndicatorClient.runningPID() ?? 0),
            ], json: json)
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = IndicatorServerController()
        indicatorServerController = controller
        app.delegate = controller
        app.run()
    }
}

struct IndicatorStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop indicator overlay")

    @Flag(name: .long) var json = false

    func run() throws {
        let hadRunning = IndicatorClient.isRunning()
        var stopped = false

        if hadRunning {
            stopped = IndicatorClient.send(.stop)
            let deadline = Date().addingTimeInterval(2.0)
            while IndicatorClient.isRunning(), Date() < deadline {
                usleep(100_000)
            }
            stopped = stopped || !IndicatorClient.isRunning()
        }

        if !stopped, let pid = IndicatorClient.runningPID() {
            if Darwin.kill(pid, SIGTERM) == 0 {
                stopped = true
            }
        }

        if stopped {
            IndicatorClient.removeStateFiles()
            try? FileManager.default.removeItem(atPath: IndicatorPaths.socket)
            JSONOutput.print(["status": "ok", "message": "Indicator stopped"], json: json)
            return
        }

        if hadRunning {
            JSONOutput.error("Failed to stop indicator", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print(["status": "ok", "message": "Indicator is not running"], json: json)
    }
}

struct IndicatorFlash: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flash", abstract: "Flash indicator pulse for one-shot feedback")

    @Flag(name: .long) var json = false

    func run() throws {
        let flashed = IndicatorClient.send(.flash)
        if !flashed {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            StandaloneIndicatorFlash.show(duration: 0.2)
        }
        JSONOutput.print(["status": "ok", "message": "Indicator flashed"], json: json)
    }
}

struct IndicatorStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show indicator status")

    @Flag(name: .long) var json = false

    func run() throws {
        let running = IndicatorClient.isRunning()
        let pid = IndicatorClient.runningPID()
        JSONOutput.print([
            "status": "ok",
            "running": running,
            "pid": Int(pid ?? 0),
            "message": running ? "Indicator is running" : "Indicator is stopped",
        ], json: json)
    }
}
