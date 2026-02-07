# 🤖 MacPilot

**Programmatic macOS control for AI agents.** Single Swift binary, zero dependencies.

MacPilot gives AI agents (Claude, GPT, Codex, etc.) full control over macOS — mouse, keyboard, screenshots, UI elements, windows, clipboard, and more. Built for automation pipelines where agents need to interact with the Mac desktop.

## ✨ Features

- **Mouse control** — click, double-click, right-click, drag, scroll
- **Keyboard input** — type text, press key combos (cmd+c, ctrl+shift+tab, etc.)
- **Screenshots** — full screen, region, or specific window capture
- **UI Accessibility** — read, find, and click UI elements by label (via Accessibility API)
- **App management** — open, focus, list, quit applications
- **Window management** — list, focus, resize, move windows
- **Clipboard** — get/set clipboard contents
- **File dialogs** — navigate macOS file open/save dialogs programmatically
- **Shell commands** — execute shell commands with output capture
- **Wait/polling** — wait for UI elements, windows, or conditions
- **JSON output** — all commands support `--json` for structured output

## 📦 Install

### Build from source (recommended)

```bash
git clone https://github.com/adhikjoshi/macpilot.git
cd macpilot
swift build -c release
```

The binary is at `.build/release/macpilot`. Optionally copy it to your PATH:

```bash
cp .build/release/macpilot /usr/local/bin/
```

### Create .app bundle (for Accessibility permissions)

Modern macOS (Sequoia+) works best with `.app` bundles for Accessibility permissions:

```bash
mkdir -p MacPilot.app/Contents/MacOS
cp .build/release/macpilot MacPilot.app/Contents/MacOS/MacPilot

cat > MacPilot.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacPilot</string>
    <key>CFBundleIdentifier</key>
    <string>com.macpilot.cli</string>
    <key>CFBundleName</key>
    <string>MacPilot</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - MacPilot.app
```

Then add `MacPilot.app` to **System Settings → Privacy & Security → Accessibility**.

## ⚙️ Requirements

- macOS 13+ (Ventura) — tested up to macOS 26 (Tahoe)
- **Accessibility permission** (System Settings → Privacy → Accessibility)
- **Screen Recording permission** (for screenshots)

## 🚀 Usage

### Mouse

```bash
macpilot click 100 200           # Left click at (100, 200)
macpilot doubleclick 100 200     # Double-click
macpilot rightclick 100 200      # Right-click
macpilot move 100 200            # Move cursor
macpilot drag 100 200 300 400    # Drag from (100,200) to (300,400)
macpilot scroll up 5             # Scroll up 5 units
macpilot scroll down 10          # Scroll down 10 units
```

### Keyboard

```bash
macpilot type "Hello World"      # Type text
macpilot key enter               # Press Enter
macpilot key cmd+c               # Copy
macpilot key cmd+shift+o         # Key combo
macpilot key tab                 # Tab
```

### Screenshots

```bash
macpilot screenshot                          # Full screen → /tmp/macpilot_screenshot.png
macpilot screenshot --output shot.png        # Custom output path
macpilot screenshot --region 0,0,500,500     # Capture region
macpilot screenshot --window Chrome          # Capture specific window
```

### UI Elements (Accessibility API)

This is the killer feature for AI agents — read and interact with UI elements programmatically:

```bash
macpilot ui list                     # List frontmost app elements
macpilot ui list --app Chrome        # List Chrome's elements
macpilot ui find "Load unpacked"     # Find element by text
macpilot ui click "Load unpacked"    # Click element by accessibility label
macpilot ui tree --app Chrome        # Full accessibility tree
```

### App Management

```bash
macpilot app open "Google Chrome"    # Open app
macpilot app focus Chrome            # Focus/bring to front
macpilot app list                    # List running apps
macpilot app quit TextEdit           # Quit gracefully
macpilot app quit TextEdit --force   # Force quit
```

### Window Management

```bash
macpilot window list                 # List all windows
macpilot window focus "Terminal"     # Focus a window
```

### Clipboard

```bash
macpilot clipboard get               # Read clipboard
macpilot clipboard set "copied text" # Set clipboard
```

### File Dialogs

Navigate macOS file open/save dialogs programmatically — useful for agents that need to upload files or save to specific locations:

```bash
macpilot dialog navigate /path/to/file
```

### Wait / Polling

```bash
macpilot wait window "Chrome"        # Wait for window to appear
macpilot wait ui "Submit" --app Chrome  # Wait for UI element
```

### JSON Output

All commands support `--json` for structured, parseable output:

```bash
macpilot app list --json
macpilot ui find "button" --app Chrome --json
macpilot screenshot --output /tmp/shot.png --json
```

## 🤖 For AI Agent Developers

MacPilot is designed to be called from AI agent tool-use pipelines. Common patterns:

```python
# Python example — screenshot + analyze
import subprocess, base64

# Take screenshot
subprocess.run(["macpilot", "screenshot", "--output", "/tmp/screen.png"])

# Read UI elements
result = subprocess.run(["macpilot", "ui", "list", "--app", "Chrome", "--json"],
                       capture_output=True, text=True)
elements = json.loads(result.stdout)

# Click a button by label
subprocess.run(["macpilot", "ui", "click", "Sign In"])

# Type into focused field
subprocess.run(["macpilot", "type", "hello@example.com"])
subprocess.run(["macpilot", "key", "tab"])
subprocess.run(["macpilot", "type", "password123"])
subprocess.run(["macpilot", "key", "enter"])
```

### Integration with OpenClaw / Claude Code

MacPilot works great with [OpenClaw](https://github.com/openclaw/openclaw) agents that need desktop automation. Add it to your agent's toolkit and use `exec` to call MacPilot commands.

## 📁 Project Structure

```
macpilot/
├── Package.swift              # Swift Package Manager config
├── Sources/MacPilot/
│   ├── MacPilot.swift         # Main entry point + CLI routing
│   ├── MouseCommands.swift    # click, doubleclick, rightclick, move, drag, scroll
│   ├── KeyboardCommands.swift # type, key
│   ├── ScreenshotCommand.swift# screenshot
│   ├── UICommands.swift       # ui list, find, click, tree
│   ├── AppCommands.swift      # app open, focus, list, quit
│   ├── WindowCommands.swift   # window list, focus
│   ├── ClipboardCommand.swift # clipboard get, set
│   ├── DialogCommands.swift   # dialog navigate
│   ├── ShellCommands.swift    # shell exec
│   └── WaitCommands.swift     # wait commands
└── README.md
```

## 📄 License

MIT — use it however you want.

## 🙏 Credits

Built by the agent squad at [ModelsLab](https://modelslab.com) for AI-powered Mac automation.
