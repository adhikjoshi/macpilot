import ArgumentParser
import AppKit
import Foundation
import UserNotifications

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
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)

        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            semaphore.signal()
        }
        semaphore.wait()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        var deliveryError: Error?

        center.add(request) { error in
            deliveryError = error
            semaphore.signal()
        }
        semaphore.wait()

        flashIndicatorIfRunning()

        if let err = deliveryError {
            JSONOutput.error("Failed to send notification: \(err.localizedDescription)", json: json)
            throw ExitCode.failure
        }

        JSONOutput.print([
            "status": "ok",
            "message": "Notification sent",
            "title": title,
            "body": body,
        ], json: json)
    }
}
