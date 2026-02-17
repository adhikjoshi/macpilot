# MacPilot

Programmatic macOS control for AI agents. Everything a human can do via keyboard + mouse, MacPilot can do programmatically.

Current version: **0.6.0**

## Quick Start

```bash
# Clone and build
git clone https://github.com/adhikjoshi/macpilot.git
cd macpilot
swift build -c release

# Build .app bundle (recommended — needed for Screen Recording permission)
bash scripts/build-app.sh

# Install to /Applications
cp -R MacPilot.app /Applications/
# Symlink for CLI access
ln -sf /Applications/MacPilot.app/Contents/MacOS/MacPilot /usr/local/bin/macpilot
```

### Permissions Required
1. **Accessibility** — System Settings > Privacy & Security > Accessibility > Add MacPilot.app
2. **Screen Recording** — System Settings > Privacy & Security > Screen Recording > Add MacPilot.app

**Note**: macOS grants permissions per CDHash — every rebuild invalidates prior grants. Re-grant after each build.

### Verify Permissions
```bash
macpilot ax-check --json
# Should show: "trusted": true
```

### Menu Bar Icon (NEW in v0.6.0)
The menu bar icon appears automatically when any macpilot command runs. Click it to see:
- Recent command activity with timestamps
- Permission status for all required permissions
- Quick links to open System Settings

## OCR + Click Navigation (AI Agent Workflow)

MacPilot's OCR uses Apple's Vision framework (on-device, no API calls) and returns **screen coordinates** you can directly feed to click commands. This is the primary navigation method for AI agents.

### Screenshot > OCR > Click Pipeline

```bash
# 1. Take screenshot
macpilot screenshot /tmp/screen.png

# 2. OCR the full screen — returns screen coordinates for every text element
macpilot ocr /tmp/screen.png --json
# Returns: { "lines": [{ "text": "Submit", "screenCenterX": 450, "screenCenterY": 300, ... }] }

# 3. Click the element using screen coordinates
macpilot click 450 300
```

### Region OCR for Precision

```bash
# OCR a specific screen region (x y width height) — faster and more accurate
macpilot ocr 0 30 2240 30 --json    # OCR just the tab bar
macpilot ocr 150 90 150 250 --json  # OCR a sidebar

# Returns same screenCenterX/Y coordinates ready for clicking
```

### OCR Output Fields

Each line in the OCR output includes:
| Field | Description |
|-------|-------------|
| `text` | Recognized text content |
| `confidence` | Recognition confidence (0-1) |
| `screenX`, `screenY` | Top-left corner in screen coordinates |
| `screenCenterX`, `screenCenterY` | **Center point — use this for clicking** |
| `screenWidth`, `screenHeight` | Size in screen coordinates |
| `x`, `y`, `width`, `height` | Raw pixel coordinates |
| `scaleFactor` | Retina scale factor (usually 2.0) |

### Multi-language OCR

```bash
macpilot ocr image.png --language ja --json   # Japanese
macpilot ocr image.png --language zh-Hans --json  # Chinese
macpilot ocr image.png --language de --json   # German
```

## Finding Elements: Three Methods

AI agents should try these methods in order:

### 1. Keyboard Shortcuts (Fastest)

```bash
# List all shortcuts for the focused app
macpilot ui shortcuts --json
# Returns: { "shortcuts": [{ "shortcut": "cmd+O", "title": "Open File…", "menuPath": "File" }, ...] }

# Use the shortcut directly
macpilot key "cmd+o"     # Open file dialog
macpilot key "cmd+t"     # New tab
macpilot key "cmd+l"     # Focus address bar
```

### 2. OCR + Click (Most Reliable)

```bash
# Find text on screen and click it
macpilot screenshot /tmp/s.png
macpilot ocr /tmp/s.png --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
for l in d['lines']:
    if 'Submit' in l['text']:
        print(l['screenCenterX'], l['screenCenterY'])"
# Then: macpilot click <x> <y>
```

### 3. Accessibility Tree (For Interactive Elements)

```bash
# Find element by label
macpilot ui find "Submit" --json

# Find elements near a position (great for icon buttons without text)
macpilot ui elements-at 340 1200 --radius 50 --json
# Returns all AX elements near that point with roles, actions, and positions

# Click by accessibility label
macpilot ui click "Submit"
```

## Commands

All commands support `--json` for structured output. **35+ command categories** with 90+ subcommands.

### Mouse
```bash
macpilot click 100 200             # left click at coordinates
macpilot doubleclick 100 200
macpilot rightclick 100 200
macpilot move 300 300
macpilot drag 100 200 300 400      # drag from (100,200) to (300,400)
macpilot scroll up 5
macpilot scroll down 10
macpilot mouse-position --json     # get current cursor position
```

### Keyboard
```bash
macpilot type "Hello World" --json
macpilot key "cmd+c" --json
macpilot key return --json
macpilot key "cmd+shift+3" --json
macpilot keyboard type "text" --json
macpilot keyboard key "ctrl+right" --json   # switch Space
```

**Alert sound detection** is enabled by default — if a keyboard command triggers an error alert sound, `alertSoundDetected: true` appears in JSON output. Disable with `--no-detect-errors`.

### Screenshot
```bash
macpilot screenshot /tmp/screen.png --json
macpilot screenshot /tmp/region.png --region 100,100,800,600 --json

# From background processes:
open -n -W -a MacPilot.app --args screenshot --output /tmp/screen.png --json
```

### App Management
```bash
macpilot app list --json                     # list running apps
macpilot app open Safari --json              # open by name
macpilot app open com.apple.TextEdit --json  # open by bundle ID
macpilot app focus Chrome --json             # bring to front
macpilot app frontmost --json                # get frontmost app
macpilot app quit Safari --json              # graceful quit
macpilot app quit Safari --force --json      # force quit
```

### Window Management
```bash
macpilot window list --json
macpilot window focus Safari --json
macpilot window move Safari 100 100 --json
macpilot window resize Safari 1200 800 --json
macpilot window minimize Safari --json
macpilot window fullscreen Safari --json
macpilot window close Safari --json
```

### UI / Accessibility
```bash
macpilot ui list --json                    # list UI elements
macpilot ui find "Submit" --json           # find element by name
macpilot ui click "Submit" --json          # click by accessibility label
macpilot ui tree --depth 3 --json          # element hierarchy
macpilot ui find-text "Search" --json      # search entire AX tree for text
macpilot ui wait-for "Submit" --timeout 10 --json  # poll until element appears
macpilot ui elements-at 340 1200 --radius 50 --json  # find elements near coordinates
macpilot ui shortcuts --json               # list all keyboard shortcuts for focused app
macpilot ui shortcuts --app Chrome --json  # list shortcuts for specific app
```

### OCR (Text Extraction + Screen Coordinates)
```bash
macpilot ocr /tmp/screen.png --json         # extract text from image with coordinates
macpilot ocr 100 100 800 600 --json         # extract from screen region (x y w h)
macpilot ocr image.png --language ja --json # custom language
```

### Chrome Browser
```bash
macpilot chrome open-url "https://example.com" --json
macpilot chrome new-tab "https://example.com" --json
macpilot chrome list-tabs --json
macpilot chrome close-tab --json
macpilot chrome extensions --json
macpilot chrome dev-mode --json
```

### Dialog / File Picker Framework
```bash
# Introspect dialog structure (see all fields, buttons, sheets)
macpilot dialog inspect --json

# Navigate to folder in open/save dialog (activates app, uses AX + Go To sheet)
macpilot dialog navigate /tmp --json
macpilot dialog navigate /Users/admin/Desktop --json

# Select a file (without auto-confirming)
macpilot dialog select myfile.txt --json
macpilot dialog select myfile.txt --confirm --json  # select + press Open

# List files visible in dialog
macpilot dialog list-files --json

# Set any text field value in dialog
macpilot dialog set-field "/path/to/file" --json
macpilot dialog set-field "filename" --focused --json

# Click any button in dialog by label
macpilot dialog click-button "Open" --json
macpilot dialog click-button "Cancel" --json

# Trigger file open/save dialogs
macpilot dialog file-open /path/to/file --json
macpilot dialog file-save /path/to/dest --json

# Modal dialog detection & handling
macpilot dialog detect --json              # detect if modal dialog is showing
macpilot dialog dismiss "Don't Save" --json  # dismiss by button name
macpilot dialog auto-dismiss --json        # smart auto-dismiss (Don't Save > OK > Cancel)
```

**Dialog Framework Approach**: Instead of hardcoded strategies, use `dialog inspect` to understand the dialog structure, then `dialog set-field` / `dialog click-button` / `dialog navigate` to interact. Works across native and Electron apps.

### Chain Commands (multi-step automation)
```bash
macpilot chain "cmd+l" "type:https://google.com" "return" --json
macpilot chain "cmd+l" "type:url" "sleep:500" "return" --delay 200 --json

# Syntax: "key_name", "cmd+key", "type:text", "sleep:ms"
```

### Clipboard
```bash
macpilot clipboard get --json
macpilot clipboard set "hello" --json
macpilot clipboard get --image --output /tmp/clip.png --json
```

### Shell
```bash
macpilot shell run "ls -la" --json
macpilot shell run "whoami" --json
```

### Visual Indicator Overlay + Menu Bar
```bash
macpilot indicator start --json            # start border glow + menu bar icon
macpilot indicator stop --json
macpilot indicator flash --json            # single flash
macpilot indicator status --json           # check if running
macpilot menubar start --json              # ensure menu bar is running (via indicator)
```

The indicator auto-starts when any command runs, flashes before every operation, and shows a teal menu bar icon with activity tracking and permission status.

### Menu Bar Navigation
```bash
macpilot menubar click Chrome "File > New Window" --json  # click app menu items
```

### Notifications
```bash
macpilot notification send "Title" "Body text" --json
```

### Audio
```bash
macpilot audio volume --json               # get current volume
macpilot audio volume 50 --json            # set volume (0-100)
macpilot audio mute --json
macpilot audio unmute --json
```

### Display
```bash
macpilot display brightness get --json
macpilot display brightness set 0.7 --json  # 0.0-1.0
macpilot display-info --json               # display resolution, refresh rate
```

### Appearance (Dark Mode)
```bash
macpilot appearance dark --json
macpilot appearance light --json
macpilot appearance toggle --json
```

### Network
```bash
macpilot network --json                    # WiFi name, IP, interfaces
```

### Process Management
```bash
macpilot process list --json               # list running processes
macpilot process kill "AppName" --json     # kill by name
```

### System Info
```bash
macpilot system info --json                # CPU, RAM, disk, OS version
```

### Screen Recording
```bash
macpilot screen record start --output /tmp/rec.mov --json
macpilot screen record stop --json
```

### Dock
```bash
macpilot dock show --json
macpilot dock hide --json
macpilot dock autohide --json
```

### Space (Desktop) Management
```bash
macpilot space list --json
macpilot space switch right --json
macpilot space switch left --json
macpilot space switch 1 --json             # by index
```

### Wait / Polling
```bash
macpilot wait element "Submit" --timeout 10 --json
macpilot wait window "Chrome" --timeout 10 --json
macpilot wait seconds 1.5 --json
```

### Login Items
```bash
macpilot login-items list --json
```

### Watch (File System)
```bash
macpilot watch /path/to/dir --json         # watch for file changes
```

### Utility
```bash
macpilot ax-check --json          # verify Accessibility permission
macpilot --version                # show version (0.6.0)
```

## Best Practices for AI Agents

### Strategy: Shortcuts > OCR > AX Tree > Manual Click

1. **Check shortcuts first** — `macpilot ui shortcuts --json` gives you the fastest path
2. **OCR for text-based navigation** — screenshot + OCR + click for buttons, tabs, links
3. **AX tree for interactive elements** — `ui elements-at` finds clickable things near known positions
4. **Manual coordinates as last resort** — when all else fails, calculate position from layout

### Validate > Act > Verify (MANDATORY)

Never fire commands blindly. Always:

1. **PRE-CHECK** state before acting
2. **ACT** — run your command
3. **POST-CHECK** — verify it worked

```bash
MP=macpilot

# Example: Navigate Chrome to a URL
$MP app focus "Google Chrome" --json       # PRE: ensure focus
$MP ui shortcuts --json                     # PRE: learn available shortcuts
$MP chain "cmd+l" "type:https://example.com" "return" --json  # ACT
sleep 2
$MP screenshot /tmp/result.png              # POST: verify
$MP ocr /tmp/result.png --json              # POST: read what loaded
```

### Complex Navigation Example

```bash
# Find and click a specific tab in Chrome
$MP screenshot /tmp/s.png
$MP ocr 0 30 2240 30 --json  # OCR just the tab bar strip
# Parse output to find tab text + coordinates, then click

# Handle icon buttons (no text)
$MP ui elements-at 340 1200 --radius 50 --json
# Find AXGroup/AXButton with actions, get centerX/centerY, then click

# Upload a file in any app (complete workflow)
$MP ui elements-at 340 1223 --radius 30 --json     # Find upload button
$MP click 340 1223 --json                           # Click it
sleep 0.8
$MP screenshot /tmp/menu.png && $MP ocr /tmp/menu.png --json  # Find "Upload a File"
$MP click 395 1065 --json                           # Click menu item
sleep 1.5
$MP dialog detect --json                            # Verify dialog opened
$MP dialog navigate /Users/admin/Desktop --json     # Navigate to folder
$MP click 520 590 --json                            # Click a file
$MP dialog click-button "Open" --json               # Confirm selection

# Debug a dialog (inspect its structure)
$MP dialog inspect --json                           # See all fields, buttons, sheets
$MP dialog set-field "/custom/path" --focused --json  # Set text in focused field
$MP dialog list-files --json                        # List visible files
```

### Modal Dialog Handling
When a modal dialog appears unexpectedly (Save changes? etc.), it blocks all other input:
```bash
$MP dialog detect --json                   # check for modal
$MP dialog auto-dismiss --json             # smart dismiss
# Priority: Don't Save > OK > Cancel
```

### Key Rules
- **Shortcuts first** — always check `ui shortcuts` before trying to click
- **One app at a time** — finish with one before starting another
- **Always confirm focus** before typing/clicking
- **Sleep 1-2s** after opening apps (they need time to load)
- **Check for modal dialogs** if operations seem stuck
- **Use region OCR** for precision — OCR just the area you need, not the full screen
- **Clean up** — close apps/tabs you opened

## Build

```bash
swift build                                    # debug build
swift build -c release                         # release build
bash scripts/build-app.sh                      # build .app bundle with ad-hoc signing
```

## CI / CD

- **CI**: Runs on every PR and merge to main (build + test + .app verification)
- **Release**: Push a tag (`git tag v0.6.0 && git push --tags`) to auto-create a GitHub Release with .app zip + standalone binary

## Safety

MacPilot has built-in safety limits:
- **Protected processes**: Finder, Dock, WindowServer, SystemUIServer, launchd, kernel_task cannot be quit
- **Protected paths**: System directories cannot be modified via shell
- **Shell safety**: Dangerous commands are blocked
- **Alert sound detection**: Detects error alert sounds on keyboard commands (enabled by default)
- **Visual indicator**: Border glow overlay + menu bar icon shows when MacPilot is actively controlling the machine
- **Activity tracking**: Menu bar shows recent commands (in-memory only, not logged)

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- Accessibility permission (required for all commands)
- Screen Recording permission (required for screenshots)

## License

MIT
