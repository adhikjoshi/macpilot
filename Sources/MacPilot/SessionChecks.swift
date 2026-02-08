import AppKit
import ArgumentParser
import Foundation

func hasActiveUserSession() -> Bool {
    if NSWorkspace.shared.frontmostApplication != nil {
        return true
    }
    return !NSWorkspace.shared.runningApplications.isEmpty
}

func requireActiveUserSession(json: Bool, actionDescription: String) throws {
    guard hasActiveUserSession() else {
        JSONOutput.error("No active macOS user session available for \(actionDescription)", json: json)
        throw ExitCode.failure
    }
}
