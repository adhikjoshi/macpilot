import XCTest
import Foundation

final class MacPilotTests: XCTestCase {

    static let binaryPath: String = {
        if let env = ProcessInfo.processInfo.environment["MACPILOT_BIN"], !env.isEmpty {
            return env
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/macpilot").path
    }()

    @discardableResult
    func runMacPilot(_ args: [String], expectSuccess: Bool = true) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.binaryPath)
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        try task.run()
        task.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if expectSuccess {
            XCTAssertEqual(task.terminationStatus, 0, "Expected success but got exit code \(task.terminationStatus). stderr: \(stderr)")
        }

        return (stdout, stderr, task.terminationStatus)
    }

    func testAXCheck() throws {
        let result = try runMacPilot(["ax-check", "--json"])
        XCTAssertTrue(result.stdout.contains("AXIsProcessTrusted"))
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertNotNil(json["trusted"])
    }

    func testRunCommandHasBundleMissingGuidance() throws {
        let result = try runMacPilot(["run", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("build-app.sh") || result.stderr.contains("build-app.sh"))
    }

    func testVersion() throws {
        let result = try runMacPilot(["--version"])
        XCTAssertTrue(result.stdout.contains("0.4.0"))
    }

    func testWaitWindowByTitleGraceful() throws {
        let result = try runMacPilot(["wait", "window", "__definitely_not_a_window__", "--timeout", "0.2", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Timeout waiting for window"))
    }

    func testWindowFocusGracefulFailureForMissingApp() throws {
        let result = try runMacPilot(["window", "focus", "--app", "__not_running__", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("App not running"))
    }

    func testAppLaunchSupportsJSONFlag() throws {
        let result = try runMacPilot(["app", "launch", "__definitely_missing_app__", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 64, "Parser rejected --json for app launch")
        XCTAssertTrue(result.stdout.contains("\"status\""))
    }

    func testAppFrontmostSupportsJSONFlag() throws {
        let result = try runMacPilot(["app", "frontmost", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 64, "Parser rejected --json for app frontmost")
        XCTAssertTrue(result.stdout.contains("\"status\""))
    }

    func testChromeListTabsSupportsJSONFlag() throws {
        let result = try runMacPilot(["chrome", "list-tabs", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 64, "Parser rejected --json for chrome list-tabs")
        XCTAssertTrue(result.stdout.contains("\"status\""))
    }
}
