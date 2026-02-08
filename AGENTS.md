# AGENTS.md

## ⚠️ CRITICAL: Validate → Act → Verify Pattern

**NEVER fire a MacPilot command without checking state first. NEVER assume the previous step worked.**

Every MacPilot operation MUST follow this 3-step pattern:

### 1. PRE-CHECK (Validate)
Before any action, check the current state:
- `window list --json` → What windows are open? Which is frontmost?
- `app list --json` → Is the target app running?
- `screenshot` → What does the screen actually look like?

### 2. ACT (Execute)
Run your command only after confirming preconditions are met.

### 3. POST-CHECK (Verify)
After the action, verify it worked:
- `window list --json` → Did focus change? Did the window move/resize?
- `screenshot` → Does the screen show what we expect?
- Check exit code + JSON output for errors

### Examples

**BAD (fire and pray):**
```bash
MacPilot app open Safari
MacPilot chain "cmd+l" "type:https://google.com" "return"
MacPilot screenshot --output /tmp/result.png
```

**GOOD (validate → act → verify):**
```bash
# PRE-CHECK: Is Safari already running?
MacPilot app list --json | grep Safari

# ACT: Open Safari
MacPilot app open Safari --json
sleep 2

# POST-CHECK: Is Safari now frontmost?
MacPilot window list --json  # verify Safari window exists and is focused

# PRE-CHECK: Confirm Safari is focused before typing
MacPilot window focus Safari --json

# ACT: Navigate
MacPilot chain "cmd+l" "type:https://google.com" "return" --json
sleep 3

# POST-CHECK: Verify with screenshot
MacPilot screenshot --output /tmp/result.png --json
# Verify screenshot shows Google, not wallpaper
```

### Rules for Multi-Step Operations
1. **One app at a time.** Don't open 5 apps and try to control them all. Finish with one, then move to the next.
2. **Always confirm focus.** Before typing/clicking in an app, run `window focus <app>` and verify.
3. **Sleep after app launches.** Apps need 2-3 seconds to fully load. Don't type into nothing.
4. **Clean up after yourself.** Close apps/tabs you opened for testing.
5. **Check window list before window operations.** Don't try to resize a window that doesn't exist.
6. **Screenshot to verify visual state.** When CLI output isn't enough, take a screenshot and check.

---

## Project overview
MacPilot is a Swift command-line tool for macOS automation. It exposes mouse, keyboard, window, app, UI Accessibility, Space/desktop, screenshot, shell, and orchestration commands so scripts/agents can control macOS reliably.

## Architecture
- **Build system:** Swift Package Manager (SPM)
- **Entry point:** `Sources/MacPilot/MacPilot.swift`
- **Command model:** `ArgumentParser` with one top-level command (`macpilot`) and many subcommands
- **Organization:** command families are split by file (e.g., `WindowCommands.swift`, `SpaceCommands.swift`, `UICommands.swift`)
- **Safety:** `SafetyChecks.swift` guards dangerous process/path/shell operations

## Build
- Debug/default build:
  - `swift build`
- Release build:
  - `swift build -c release`

## Test
- XCTest suite:
  - `swift test`
- Integration script:
  - `bash Tests/run_tests.sh`

## Test expectations
- **XCTest (`Tests/MacPilotTests/MacPilotTests.swift`) validates:**
  - `ax-check --json` returns valid JSON with `status=ok` and `trusted`
  - `run --json` returns bundle-missing guidance (`build-app.sh`) when app bundle is absent
  - `--version` prints `0.4.0`
  - `wait window ... --timeout ... --json` times out gracefully
  - `window focus --app ... --json` fails gracefully for missing apps
- **Integration script (`Tests/run_tests.sh`) validates:**
  - Binary exists and is executable
  - Version output is correct
  - AX check JSON output
  - Wait timeout behavior
  - Window focus missing-app behavior
  - Run command guidance behavior

## CRITICAL compatibility rules (do not break)
1. All existing CLI syntax must continue working.
2. New commands/options must follow existing command-family patterns.
3. Tests must pass before opening/updating a PR.
4. Where a command supports both forms, keep both:
   - positional arguments
   - flag-based arguments

## Command list and expected syntax

### Top-level
`macpilot <subcommand> [options]`

### Mouse / pointer
- `click <x> <y> [--json]`
- `double-click <x> <y> [--json]`
- `right-click <x> <y> [--json]`
- `move <x> <y> [--duration <seconds>] [--json]`
- `drag <x1> <y1> <x2> <y2> [--duration <seconds>] [--json]`
- `scroll <deltaY> [--delta-x <deltaX>] [--json]`

### Keyboard / text
- `type <text> [--interval <seconds>] [--json]`
- `key <key-combo> [--json]`

### Screenshot
- `screenshot [--output <path>] [--format png|jpg] [--json]`

### UI accessibility
- `ui list [--app <name>] [--depth <n>] [--json]`
- `ui find <query> [--app <name>] [--json]`
- `ui click <label> [--app <name>] [--json]`
- `ui tree [--app <name>] [--depth <n> | --max-depth <n>] [--json]`

### App lifecycle
- `app list [--json]`
- `app launch <name> [--json]`
- `app quit <name> [--force] [--json]`
- `app activate <name> [--json]`
- `app frontmost [--json]`

### Clipboard
- `clipboard get [--json]`
- `clipboard set <text> [--json]`

### Window management
- `window list [--app <name>] [--all-spaces] [--json]`
- `window focus <app> [--title <substring>] [--json]`
- `window focus --app <app> [--title <substring>] [--json]`
- `window move <app> <x> <y> [--json]`
- `window move --app <app> --x <x> --y <y> [--json]`
- `window resize <app> <width> <height> [--json]`
- `window resize --app <app> --width <w> --height <h> [--json]`
- `window close --app <app> [--json]`
- `window minimize <app> [--json]`
- `window minimize --app <app> [--json]`
- `window fullscreen <app> [--json]`
- `window fullscreen --app <app> [--json]`

### Dialog
- `dialog alert <message> [--title <title>] [--json]`
- `dialog confirm <message> [--title <title>] [--json]`
- `dialog prompt <message> [--title <title>] [--default <text>] [--json]`

### Shell
- `shell run <command> [--timeout <seconds>] [--json]`

### Wait helpers
- `wait seconds <seconds> [--json]`
- `wait app <name> [--timeout <seconds>] [--json]`
- `wait window <title> [--timeout <seconds>] [--json]`

### Spaces / desktops
- `space list [--json]`
- `space switch <left|right|1..9> [--json]`
- `space switch --direction <left|right> [--json]`
- `space switch --index <1..9> [--json]`
- `space bring --app <name> [--json]`

### Diagnostics / orchestration
- `ax-check [--json]`
- `chain <json-file-or-inline> [--json]`
- `chrome ...`
- `run [--json]`

> Note: If adding/changing any command syntax, preserve old forms unless explicitly removed in a versioned breaking-change plan.

## File structure
- `Package.swift` — SPM package definition
- `Sources/MacPilot/MacPilot.swift` — CLI root command registration
- `Sources/MacPilot/*Commands.swift` — grouped command families
- `Sources/MacPilot/SafetyChecks.swift` — process/path/shell safety rules
- `Tests/MacPilotTests/MacPilotTests.swift` — XCTest coverage
- `Tests/run_tests.sh` — integration smoke tests against release binary

## Safety limits (hard boundaries)
From `SafetyChecks.swift`, MacPilot must not kill protected system processes or operate on protected system paths.

### Protected processes (must never be killed)
- Finder
- WindowServer
- Dock
- SystemUIServer
- launchd
- kernel_task
- loginwindow
- cfprefsd
- lsd
- mds
- notifyd
- distnoted
- securityd
- trustd
- tccd
- coreservicesd
- opendirectoryd
- syslogd
- powerd
- diskarbitrationd
- configd
- UserEventAgent

### Protected paths (must never be modified)
- `/System/`
- `/Library/`
- `/usr/`
- `/bin/`
- `/sbin/`
- `/private/var/db/TCC/`
- `/etc/sudoers`
- `/etc/hosts`

### Shell safety checks enforced
- Reject commands that attempt TCC DB access
- Reject destructive system-path deletion patterns
- Reject kill/killall against protected processes
