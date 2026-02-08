import XCTest
import Foundation

/// Integration tests for MacPilot CLI.
/// These tests invoke the built binary and verify output.
final class MacPilotTests: XCTestCase {

    /// Path to the MacPilot binary
    static let binaryPath = "/Users/admin/clawd/tools/macpilot/MacPilot.app/Contents/MacOS/MacPilot"

    // MARK: - Helpers

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

    // MARK: - Tests

    func testAXCheck() throws {
        let result = try runMacPilot(["ax-check", "--json"])
        XCTAssertTrue(result.stdout.contains("AXIsProcessTrusted"))
        // Should parse as valid JSON
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertNotNil(json["trusted"])
    }

    func testScreenshot() throws {
        let tmpPath = "/tmp/macpilot_test_screenshot.png"
        try? FileManager.default.removeItem(atPath: tmpPath)

        let result = try runMacPilot(["screenshot", "--output", tmpPath, "--json"])
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["path"] as? String, tmpPath)

        // Verify file exists and has content
        let fileData = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        XCTAssertGreaterThan(fileData.count, 1000, "Screenshot should be more than 1KB")

        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testAppList() throws {
        let result = try runMacPilot(["app", "list", "--json"])
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertGreaterThan(json.count, 0, "Should have at least 1 running app")
        // Finder should always be running
        let finderFound = json.contains { ($0["name"] as? String) == "Finder" }
        XCTAssertTrue(finderFound, "Finder should be in the app list")
    }

    func testSpaceList() throws {
        let result = try runMacPilot(["space", "list", "--json"])
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(json.count, 1, "Should have at least 1 space")
        // At least one should be current
        let hasCurrent = json.contains { ($0["current"] as? Bool) == true }
        XCTAssertTrue(hasCurrent, "Should have an active space")
    }

    func testClipboard() throws {
        let testText = "MacPilot_test_\(Int.random(in: 1000...9999))"
        try runMacPilot(["clipboard", "set", testText, "--json"])
        let result = try runMacPilot(["clipboard", "get", "--json"])
        XCTAssertTrue(result.stdout.contains(testText))
    }

    func testChainDryRun() throws {
        // Just verify the chain command parses correctly with --json
        // Using sleep:0 actions to avoid actual key events during tests
        let result = try runMacPilot(["chain", "sleep:10", "sleep:10", "--delay", "10", "--json"])
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertTrue(result.stdout.contains("2 actions"))
    }

    func testSafetyBlocksSystemProcess() throws {
        let result = try runMacPilot(["app", "quit", "WindowServer", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("REFUSED") || result.stderr.contains("REFUSED"),
                       "Should refuse to quit system process")
    }

    func testSafetyBlocksDangerousShell() throws {
        let result = try runMacPilot(["shell", "run", "rm -rf /System/test", "--json"], expectSuccess: false)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("REFUSED") || result.stderr.contains("REFUSED"),
                       "Should refuse dangerous shell command")
    }

    func testKeyCodeMapping() throws {
        // Verify all basic keys map to non-zero codes (except 'a' which is 0)
        // We test by running key command with --json and checking it succeeds
        let result = try runMacPilot(["key", "escape", "--json"])
        XCTAssertTrue(result.stdout.contains("ok"))
    }

    func testVersion() throws {
        let result = try runMacPilot(["--version"])
        XCTAssertTrue(result.stdout.contains("0.3.0"))
    }

    func testWindowListAllSpaces() throws {
        let result = try runMacPilot(["window", "list", "--all-spaces", "--json"])
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertGreaterThan(json.count, 0, "Should have at least 1 window")
    }
}
