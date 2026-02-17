import Foundation

// Standalone test runner (no XCTest dependency - works with Command Line Tools)

var passed = 0
var failed = 0
var errors: [String] = []

let binaryPath: String = {
    if let env = ProcessInfo.processInfo.environment["MACPILOT_BIN"], !env.isEmpty {
        return env
    }
    // Try debug first, then release
    let debug = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/macpilot").path
    if FileManager.default.fileExists(atPath: debug) { return debug }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/release/macpilot").path
}()

func runMacPilot(_ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: binaryPath)
    task.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return ("", "Failed to run: \(error)", 1)
    }

    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (stdout, stderr, task.terminationStatus)
}

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition {
        let err = "FAIL: \(message) (\(URL(fileURLWithPath: file).lastPathComponent):\(line))"
        errors.append(err)
        failed += 1
    } else {
        passed += 1
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  ✓ \(name)")
    } catch {
        let err = "FAIL: \(name) - \(error)"
        errors.append(err)
        failed += 1
        print("  ✗ \(name) - \(error)")
    }
}

// ──────────────────────────────────────────────
// TESTS
// ──────────────────────────────────────────────

print("MacPilot v0.6.0 Tests")
print("Binary: \(binaryPath)")
print("─────────────────────────────────────────")

// Core
test("Version") {
    let r = runMacPilot(["--version"])
    assert(r.stdout.contains("0.6.0"), "Version should be 0.6.0, got: \(r.stdout)")
}

test("Help") {
    let r = runMacPilot(["--help"])
    assert(r.stdout.contains("macpilot"), "Help should contain macpilot")
    assert(r.stdout.contains("SUBCOMMANDS"), "Help should contain SUBCOMMANDS")
}

test("AX Check JSON") {
    let r = runMacPilot(["ax-check", "--json"])
    assert(r.stdout.contains("AXIsProcessTrusted"), "Should contain AXIsProcessTrusted")
    assert(r.stdout.contains("\"status\""), "Should be valid JSON")
}

// Gap C: Mouse Position
test("Mouse Position JSON") {
    let r = runMacPilot(["mouse-position", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("\"x\""), "Should have x coordinate")
    assert(r.stdout.contains("\"y\""), "Should have y coordinate")
}

test("Mouse Position Plain") {
    let r = runMacPilot(["mouse-position"])
    assert(r.stdout.contains("Mouse at"), "Should show mouse position")
}

// Gap E: Display Info
test("Display Info JSON") {
    let r = runMacPilot(["display-info", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("width"), "Should have width")
    assert(r.stdout.contains("scaleFactor"), "Should have scaleFactor")
}

test("Display Info Plain") {
    let r = runMacPilot(["display-info"])
    assert(r.stdout.contains("Display 0"), "Should show Display 0")
}

// Gap H: Menu Commands
test("Menu Help") {
    let r = runMacPilot(["menu", "--help"])
    assert(r.stdout.contains("click"), "Menu should have click subcommand")
    assert(r.stdout.contains("list"), "Menu should have list subcommand")
}

test("Menu List Missing App") {
    let r = runMacPilot(["menu", "list", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

// Gap Q: Clipboard Watch
test("Clipboard Watch Short Duration") {
    let r = runMacPilot(["clipboard", "watch", "--duration", "0.3", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("\"status\" : \"ok\""), "Should return ok status")
    assert(r.stdout.contains("changeCount"), "Should have changeCount")
}

// Gap S: App Hide/Unhide
test("App Hide Missing App") {
    let r = runMacPilot(["app", "hide", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
    assert(r.stdout.contains("not running"), "Should say not running")
}

test("App Unhide Missing App") {
    let r = runMacPilot(["app", "unhide", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
    assert(r.stdout.contains("not running"), "Should say not running")
}

// Gap N: Window Snap
test("Window Snap Missing App") {
    let r = runMacPilot(["window", "snap", "--app", "__not_running__", "--snap", "left", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

// Gap T: Window Restore
test("Window Restore No Saved Layout") {
    let stateFile = NSHomeDirectory() + "/.macpilot_window_state.json"
    if FileManager.default.fileExists(atPath: stateFile) {
        try? FileManager.default.removeItem(atPath: stateFile)
    }
    let r = runMacPilot(["window", "restore", "--json"])
    assert(r.exitCode != 0, "Should fail with no saved layout")
    assert(r.stdout.contains("No saved layout"), "Should mention no saved layout")
}

// Gap V: Login Items
test("Login Items JSON") {
    let r = runMacPilot(["login-items", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("\"status\" : \"ok\""), "Should return ok status")
    assert(r.stdout.contains("count"), "Should have count")
    assert(r.stdout.contains("items"), "Should have items")
}

// Gap W: Watch Events
test("Watch Events Short Duration") {
    let r = runMacPilot(["watch", "events", "--duration", "0.3", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("\"status\" : \"ok\""), "Should return ok status")
    assert(r.stdout.contains("eventCount"), "Should have eventCount")
}

// UI Commands (Gaps A, B, I, G, P, K, L, O)
test("UI Set-Value Missing App") {
    let r = runMacPilot(["ui", "set-value", "test", "value", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

test("UI Get-Value Missing App") {
    let r = runMacPilot(["ui", "get-value", "test", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

test("UI Set-Focus Missing App") {
    let r = runMacPilot(["ui", "set-focus", "test", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

test("UI Scroll Missing App") {
    let r = runMacPilot(["ui", "scroll", "test", "down", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

test("UI Attributes Missing App") {
    let r = runMacPilot(["ui", "attributes", "test", "--app", "__not_running__", "--json"])
    assert(r.exitCode != 0, "Should fail for missing app")
}

// Gap K: --exact flag
test("UI Find --exact Flag Accepted") {
    let r = runMacPilot(["ui", "find", "test", "--app", "__not_running__", "--exact", "--json"])
    assert(r.exitCode != 64, "Parser should accept --exact flag (exit 64 = parser error)")
}

// Gap L: --role filter
test("UI Find --role Flag Accepted") {
    let r = runMacPilot(["ui", "find", "test", "--app", "__not_running__", "--role", "AXButton", "--json"])
    assert(r.exitCode != 64, "Parser should accept --role flag")
}

// Gap O: --hierarchy flag
test("UI List --hierarchy Flag Accepted") {
    let r = runMacPilot(["ui", "list", "--app", "__not_running__", "--hierarchy", "--json"])
    assert(r.exitCode != 64, "Parser should accept --hierarchy flag")
}

// Gap U: OCR --language flag
test("OCR --language Flag Accepted") {
    let r = runMacPilot(["ocr", "/nonexistent.png", "--language", "ja", "--json"])
    assert(r.exitCode != 64, "Parser should accept --language flag")
}

// Clipboard
test("Clipboard Get JSON") {
    let r = runMacPilot(["clipboard", "get", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("\"status\" : \"ok\""), "Should return ok")
}

test("Clipboard Set and Get") {
    let testStr = "macpilot_test_\(UUID().uuidString.prefix(8))"
    _ = runMacPilot(["clipboard", "set", testStr, "--json"])
    let r = runMacPilot(["clipboard", "get", "--json"])
    assert(r.stdout.contains(testStr), "Clipboard should contain test string")
}

// App list
test("App List JSON") {
    let r = runMacPilot(["app", "list", "--json"])
    assert(r.exitCode == 0, "Should succeed")
    assert(r.stdout.contains("name"), "Should have app names")
    assert(r.stdout.contains("pid"), "Should have PIDs")
}

test("App Frontmost JSON") {
    let r = runMacPilot(["app", "frontmost", "--json"])
    assert(r.exitCode != 64, "Parser should accept --json")
    assert(r.stdout.contains("\"status\""), "Should return status")
}

// Window list
test("Window List JSON") {
    let r = runMacPilot(["window", "list", "--json"])
    assert(r.exitCode == 0, "Should succeed")
}

// Subcommand registration
test("All New Top-Level Commands Registered") {
    let r = runMacPilot(["--help"])
    assert(r.stdout.contains("mouse-position"), "mouse-position not registered")
    assert(r.stdout.contains("display-info"), "display-info not registered")
    assert(r.stdout.contains("menu "), "menu not registered")
    assert(r.stdout.contains("watch"), "watch not registered")
    assert(r.stdout.contains("login-items"), "login-items not registered")
}

test("UI Subcommands Registered") {
    let r = runMacPilot(["ui", "--help"])
    assert(r.stdout.contains("set-value"), "ui set-value not registered")
    assert(r.stdout.contains("get-value"), "ui get-value not registered")
    assert(r.stdout.contains("set-focus"), "ui set-focus not registered")
    assert(r.stdout.contains("scroll"), "ui scroll not registered")
    assert(r.stdout.contains("attributes"), "ui attributes not registered")
}

test("Window Subcommands Registered") {
    let r = runMacPilot(["window", "--help"])
    assert(r.stdout.contains("snap"), "window snap not registered")
    assert(r.stdout.contains("restore"), "window restore not registered")
}

test("App Subcommands Registered") {
    let r = runMacPilot(["app", "--help"])
    assert(r.stdout.contains("hide"), "app hide not registered")
    assert(r.stdout.contains("unhide"), "app unhide not registered")
}

test("Clipboard Subcommands Registered") {
    let r = runMacPilot(["clipboard", "--help"])
    assert(r.stdout.contains("watch"), "clipboard watch not registered")
}

test("Menu Subcommands Registered") {
    let r = runMacPilot(["menu", "--help"])
    assert(r.stdout.contains("click"), "menu click not registered")
    assert(r.stdout.contains("list"), "menu list not registered")
}

test("Wait/Window Graceful Timeout") {
    let r = runMacPilot(["wait", "window", "__no_window__", "--timeout", "0.2", "--json"])
    assert(r.exitCode != 0, "Should fail with timeout")
    assert(r.stdout.contains("Timeout"), "Should mention timeout")
}

// ──────────────────────────────────────────────
// RESULTS
// ──────────────────────────────────────────────
print("─────────────────────────────────────────")
print("Results: \(passed) passed, \(failed) failed")
if !errors.isEmpty {
    print("\nFailures:")
    for e in errors {
        print("  \(e)")
    }
}
exit(failed > 0 ? 1 : 0)
