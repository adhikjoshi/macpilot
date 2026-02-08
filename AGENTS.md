# AGENTS.md

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
