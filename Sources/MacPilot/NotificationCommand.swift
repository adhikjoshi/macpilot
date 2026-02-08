import ArgumentParser
import AppKit
import Foundation

struct NotificationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Notification center utilities",
        subcommands: [NotificationSend.self]
    )
}

struct NotificationSend: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Send a system notification")

    @Argument(help: "Notification title") var title: String
    @Argument(help: "Notification body") var body: String
    @Flag(name: .long) var json = false

    func run() throws {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body

        flashIndicatorIfRunning()
        NSUserNotificationCenter.default.deliver(notification)

        JSONOutput.print([
            "status": "ok",
            "message": "Notification sent",
            "title": title,
            "body": body,
        ], json: json)
    }
}
