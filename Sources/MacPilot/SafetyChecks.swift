import Foundation

/// Safety checks to prevent dangerous operations.
/// MacPilot MUST NOT: kill system processes, modify system files, or touch TCC databases.
enum Safety {

    /// System processes that must never be killed
    static let protectedProcesses: Set<String> = [
        "Finder", "WindowServer", "Dock", "SystemUIServer", "launchd",
        "kernel_task", "loginwindow", "cfprefsd", "lsd", "mds",
        "notifyd", "distnoted", "securityd", "trustd", "tccd",
        "coreservicesd", "opendirectoryd", "syslogd", "powerd",
        "diskarbitrationd", "configd", "UserEventAgent",
    ]

    /// Paths that must never be modified
    static let protectedPaths: [String] = [
        "/System/",
        "/Library/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/private/var/db/TCC/",
        "/etc/sudoers",
        "/etc/hosts",
    ]

    /// Check if an app name is a protected system process
    static func isProtectedProcess(_ name: String) -> Bool {
        return protectedProcesses.contains(where: { name.localizedCaseInsensitiveCompare($0) == .orderedSame })
    }

    /// Check if a path is protected
    static func isProtectedPath(_ path: String) -> Bool {
        let resolved = (path as NSString).standardizingPath
        return protectedPaths.contains(where: { resolved.hasPrefix($0) })
    }

    /// Validate that a quit/kill operation is safe
    static func validateQuit(appName: String) -> String? {
        if isProtectedProcess(appName) {
            return "REFUSED: '\(appName)' is a protected system process. MacPilot will never kill system processes."
        }
        return nil
    }

    /// Validate that a shell command is safe
    static func validateShellCommand(_ command: String) -> String? {
        let lower = command.lowercased()

        // Block TCC database access
        if lower.contains("tcc.db") || lower.contains("/tcc/") {
            return "REFUSED: MacPilot will never access TCC databases."
        }

        // Block rm -rf on system dirs
        if lower.contains("rm ") && (lower.contains("/system") || lower.contains("/library") || lower.contains("/usr")) {
            return "REFUSED: MacPilot will never delete system files."
        }

        // Block killing system processes
        if (lower.contains("kill ") || lower.contains("killall ")) {
            for proc in protectedProcesses {
                if lower.contains(proc.lowercased()) {
                    return "REFUSED: MacPilot will never kill system process '\(proc)'."
                }
            }
        }

        return nil
    }
}
