import ArgumentParser
import AppKit
import Foundation

// MARK: - Gap W: Event watcher mode

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch for system events (app focus, window changes, clipboard)",
        subcommands: [WatchEvents.self]
    )
}

struct WatchEvents: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Monitor system events for a duration")

    @Option(name: .long, help: "Duration in seconds to watch") var duration: Double = 10
    @Option(name: .long, help: "Poll interval in milliseconds") var interval: Int = 500
    @Flag(name: .long) var json = false

    func run() throws {
        let deadline = Date().addingTimeInterval(duration)
        var events: [[String: Any]] = []
        var lastApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var lastClipboard = NSPasteboard.general.changeCount
        var lastWindowTitles = currentWindowTitles()

        if !json {
            print("Watching for events (\(Int(duration))s)...")
        }

        while Date() < deadline {
            // Check app focus change
            let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if currentApp != lastApp {
                let event: [String: Any] = [
                    "type": "app_focus",
                    "from": lastApp,
                    "to": currentApp,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                events.append(event)
                if !json { print("  App focus: \(lastApp) -> \(currentApp)") }
                lastApp = currentApp
            }

            // Check clipboard change
            let currentClipboard = NSPasteboard.general.changeCount
            if currentClipboard != lastClipboard {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                let preview = text.prefix(50)
                let event: [String: Any] = [
                    "type": "clipboard",
                    "preview": String(preview),
                    "length": text.count,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                events.append(event)
                if !json { print("  Clipboard changed: \"\(preview)\"") }
                lastClipboard = currentClipboard
            }

            // Check window changes
            let currentTitles = currentWindowTitles()
            let newWindows = currentTitles.subtracting(lastWindowTitles)
            let closedWindows = lastWindowTitles.subtracting(currentTitles)
            for title in newWindows {
                let event: [String: Any] = [
                    "type": "window_opened",
                    "title": title,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                events.append(event)
                if !json { print("  Window opened: \(title)") }
            }
            for title in closedWindows {
                let event: [String: Any] = [
                    "type": "window_closed",
                    "title": title,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                events.append(event)
                if !json { print("  Window closed: \(title)") }
            }
            lastWindowTitles = currentTitles

            usleep(UInt32(interval) * 1000)
        }

        if json {
            JSONOutput.print([
                "status": "ok",
                "duration": duration,
                "eventCount": events.count,
                "events": events,
            ], json: true)
        } else {
            print("Done. \(events.count) event(s) detected.")
        }
    }

    private func currentWindowTitles() -> Set<String> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var titles: Set<String> = []
        for win in windows {
            let layer = win[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let owner = win[kCGWindowOwnerName as String] as? String ?? ""
            let title = win[kCGWindowName as String] as? String ?? ""
            if !owner.isEmpty {
                titles.insert("\(owner): \(title)")
            }
        }
        return titles
    }
}
