# 🤖 MacPilot

Programmatic macOS control for AI agents. Everything a human can do via keyboard + mouse, MacPilot can do programmatically.

Current version: **0.4.1**

## Quick Start

```bash
# Clone and build
git clone https://github.com/adhikjoshi/macpilot.git
cd macpilot
swift build -c release

# Build .app bundle (recommended — needed for Screen Recording permission)
bash scripts/build-app.sh

# Install to a location
cp -R MacPilot.app /path/to/your/tools/
```

### Permissions Required
1. **Accessibility** — System Settings → Privacy & Security → Accessibility → Add MacPilot.app
2. **Screen Recording** — System Settings → Privacy & Security → Screen Recording → Add MacPilot.app

### Verify Permissions
```bash
MacPilot ax-check --json
# Should show: "trusted": true
```

## ⚠️ Important: Screenshot Invocation

When calling MacPilot from a background process (e.g., AI agent, cron, daemon), **screenshots require the .app identity** for Screen Recording permission:

```bash
# ✅ For screenshots (uses .app's Screen Recording permission)
open -n -W -a /path/to/MacPilot.app --args screenshot --output /tmp/screen.png --json

# ✅ For all other commands (direct binary is fine)
MP=/path/to/MacPilot.app/Contents/MacOS/MacPilot
$MP window list --json
$MP keyboard type "hello" --json
$MP mouse click 100 200 --json
```

## Commands

All commands support `--json` for structured output.

### Mouse
```bash
MacPilot mouse move 300 300 --json
MacPilot mouse click 100 200 --json
MacPilot mouse click 100 200 --right --json       # right click
MacPilot mouse doubleclick 100 200 --json
MacPilot mouse drag 100 200 300 400 --json
MacPilot mouse scroll up 5 --json
MacPilot mouse scroll down 10 --json
```

### Keyboard
```bash
MacPilot keyboard type "Hello World" --json
MacPilot keyboard key return --json
MacPilot keyboard key escape --json
MacPilot keyboard key tab --json
MacPilot keyboard key space --json
MacPilot keyboard key delete --json
MacPilot keyboard key "cmd+c" --json              # keyboard shortcuts
MacPilot keyboard key "cmd+shift+3" --json         # screenshot shortcut
MacPilot keyboard key "ctrl+right" --json          # switch Space
```

### Screenshot
```bash
# Full screen
MacPilot screenshot --output /tmp/screen.png --json

# Region capture (x,y,width,height)
MacPilot screenshot --region 100,100,800,600 --output /tmp/region.png --json

# Note: From background processes, use:
open -n -W -a MacPilot.app --args screenshot --output /tmp/screen.png --json
```

### App Management
```bash
MacPilot app open Safari --json              # open by name
MacPilot app open com.apple.TextEdit --json  # open by bundle ID
MacPilot app list --json                     # list running apps
MacPilot app quit Safari --json              # graceful quit
MacPilot app quit Safari --force --json      # force quit
# Note: System processes (Finder, Dock, etc.) are protected and cannot be quit
```

### Window Management
Both positional and flag syntax supported:
```bash
MacPilot window list --json                        # list all windows
MacPilot window focus Safari --json                # positional
MacPilot window focus --app Safari --json          # flag syntax
MacPilot window move Safari 100 100 --json         # positional: app x y
MacPilot window move --app Safari --x 100 --y 100 --json
MacPilot window resize Safari 1200 800 --json      # positional: app w h
MacPilot window resize --app Safari --width 1200 --height 800 --json
MacPilot window minimize Safari --json
MacPilot window fullscreen Safari --json           # toggle fullscreen
MacPilot window close Safari --json
```

### UI / Accessibility
```bash
MacPilot ui list --json                    # list UI elements of frontmost app
MacPilot ui find "Submit" --json           # find element by name
MacPilot ui click "Submit" --json          # click element by accessibility label
MacPilot ui tree --depth 3 --json          # element hierarchy (alias: --max-depth)
```

### Shell
```bash
MacPilot shell run "ls -la" --json
MacPilot shell run "whoami" --json
MacPilot shell run "sw_vers" --json
```

### Chain Commands (multi-step automation)
```bash
# Navigate in browser: address bar → type URL → press enter
MacPilot chain "cmd+l" "type:https://google.com" "return" --json

# With delays between steps
MacPilot chain "cmd+l" "type:https://google.com" "sleep:500" "return" --delay 200 --json

# Chain syntax:
#   "key_name"          → press key (return, escape, tab, etc.)
#   "cmd+key"           → keyboard shortcut
#   "type:text"         → type text
#   "sleep:ms"          → pause for milliseconds
```

### Chrome
```bash
MacPilot chrome open-url "https://example.com" --json
MacPilot chrome new-tab "https://example.com" --json
MacPilot chrome extensions --json
MacPilot chrome dev-mode --json
```

### Space (Desktop) Management
Both positional and flag syntax:
```bash
MacPilot space list --json
MacPilot space switch right --json              # positional
MacPilot space switch --direction right --json  # flag syntax
MacPilot space switch left --json
MacPilot space switch 1 --json                  # by index
MacPilot space switch --index 1 --json
```

### Dialog / File Picker
```bash
MacPilot dialog navigate /tmp --json
MacPilot dialog select myfile.txt --json
```

### Clipboard
```bash
MacPilot clipboard get --json
MacPilot clipboard set "hello" --json
```

### Wait
```bash
MacPilot wait element "Submit" --timeout 10 --json
MacPilot wait window "Chrome" --timeout 10 --json
MacPilot wait seconds 1.5 --json
```

### System
```bash
MacPilot ax-check --json          # verify Accessibility permission
MacPilot --version                # show version
```

## Best Practices for AI Agents

### Validate → Act → Verify (MANDATORY)

Never fire commands blindly. Always:

1. **PRE-CHECK** state before acting
2. **ACT** — run your command
3. **POST-CHECK** — verify it worked

```bash
# BAD (fire and pray)
$MP app open Safari
$MP chain "cmd+l" "type:url" "return"
$MP screenshot

# GOOD (validate → act → verify)
$MP app list --json                        # PRE: is Safari running?
$MP app open Safari --json; sleep 3        # ACT: open it
$MP window list --json                     # POST: is window visible?
$MP window focus Safari --json             # PRE: ensure focus
$MP chain "cmd+l" "type:url" "return"      # ACT: navigate
sleep 3
open -n -W -a MacPilot.app --args screenshot --output /tmp/result.png  # POST: verify
```

### Key Rules
- **One app at a time** — finish with one before starting another
- **Always confirm focus** before typing/clicking
- **Sleep 2-3s** after opening apps (they need time to load)
- **Clean up** — close apps/tabs you opened
- **Check window list** before window operations

## Build

```bash
swift build                  # debug build
swift build -c release       # release build
bash scripts/build-app.sh    # build .app bundle with ad-hoc signing
bash Tests/run_tests.sh      # run integration tests
```

## CI / CD

- **CI**: Runs on every PR and merge to main (build + test + .app verification)
- **Release**: Push a tag (`git tag v0.5.0 && git push --tags`) to auto-create a GitHub Release with .app zip + standalone binary

## Safety

MacPilot has built-in safety limits:
- **Protected processes**: Finder, Dock, WindowServer, SystemUIServer, launchd, kernel_task cannot be quit
- **Protected paths**: System directories cannot be modified via shell
- **Shell safety**: Dangerous commands are blocked

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+
- Accessibility permission (required for all commands)
- Screen Recording permission (required for screenshots)

## License

MIT
