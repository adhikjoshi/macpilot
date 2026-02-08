# 🤖 MacPilot

Programmatic macOS control for AI agents.

Current version: **0.4.0**

## Build

```bash
git clone https://github.com/adhikjoshi/macpilot.git
cd macpilot
swift build -c release
```

Binary output:

```bash
.build/release/macpilot
```

## Build `.app` bundle (recommended for Accessibility permissions)

```bash
bash scripts/build-app.sh
```

This builds release binary, assembles `MacPilot.app`, and ad-hoc signs it.

### App Bundle Structure

- `MacPilot.app/Contents/MacOS/MacPilot`
- `MacPilot.app/Contents/Info.plist`
- `MacPilot.app/Contents/Resources/`

Signing command used by script:

```bash
codesign --force --deep --sign - MacPilot.app
```

## Commands

### Mouse

```bash
macpilot click 100 200
macpilot doubleclick 100 200
macpilot rightclick 100 200
macpilot move 100 200
macpilot drag 100 200 300 400
macpilot scroll up 5
macpilot scroll down 10
```

### Keyboard

```bash
macpilot type "Hello"
macpilot key enter
macpilot key cmd+c
```

### Screenshot

```bash
macpilot screenshot
macpilot screenshot --output /tmp/screen.png
macpilot screenshot --region 0,0,500,500
macpilot screenshot --window "Google Chrome"
```

### App

```bash
macpilot app open "Google Chrome"
macpilot app open com.apple.TextEdit
macpilot app focus Chrome
macpilot app list
macpilot app quit TextEdit
macpilot app quit TextEdit --force
```

### Window

```bash
macpilot window list
macpilot window list --all-spaces
macpilot window focus --app "Terminal"
macpilot window focus --app "Google Chrome" --title "Docs"
macpilot window resize --app "Terminal" --width 1200 --height 800
macpilot window move --app "Terminal" --x 100 --y 100
macpilot window minimize --app "Terminal"
macpilot window close --app "Terminal"
macpilot window fullscreen --app "Terminal"
```

### UI

```bash
macpilot ui list
macpilot ui find "Submit"
macpilot ui click "Submit"
macpilot ui tree
```

### Other

```bash
macpilot clipboard get
macpilot clipboard set "hello"
macpilot dialog navigate /path/to/file
macpilot shell run "echo hi"
macpilot wait element "Submit" --timeout 10
macpilot wait window "Chrome" --timeout 10
macpilot wait seconds 1.5
macpilot ax-check --json
macpilot chain "sleep:10" "key:enter"
macpilot chrome tabs --json
macpilot run app list --json
```

## JSON output

Most commands support `--json`.

```bash
macpilot app list --json
macpilot window list --json
```

## Requirements

- macOS 13+
- Accessibility permission
- Screen Recording permission (screenshots)

## License

MIT
