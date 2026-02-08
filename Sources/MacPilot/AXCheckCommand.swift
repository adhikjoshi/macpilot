import ArgumentParser
import ApplicationServices
import Foundation

struct AXCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ax-check", abstract: "Check Accessibility (AX) trust status")

    @Flag(name: .long) var json = false

    func run() {
        let trusted = AXIsProcessTrusted()
        let pid = ProcessInfo.processInfo.processIdentifier
        let parentPID = getppid()
        if json {
            JSONOutput.print([
                "status": "ok",
                "trusted": trusted,
                "pid": Int(pid),
                "parentPid": Int(parentPID),
                "message": trusted ? "AXIsProcessTrusted: YES" : "AXIsProcessTrusted: NO — launch via 'open -W -a MacPilot.app' for AX access",
            ], json: true)
        } else {
            print("AXIsProcessTrusted: \(trusted ? "YES ✅" : "NO ❌")")
            print("PID: \(pid), Parent PID: \(parentPID)")
            if !trusted {
                print("Tip: Launch via 'open -W -a /path/to/MacPilot.app --args ax-check' for AX access")
            }
        }
    }
}
