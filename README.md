# xShot

A menu bar screenshot tool for macOS 15+.

| Feature | Default shortcut |
| --- | --- |
| Capture area (Space switches to window mode, click for full screen) | ⇧⌘4 |
| Capture window | — (Space during area capture) |
| Capture full screen | ⇧⌘3 |
| Scrolling capture (scroll manually or use auto-scroll) | ⇧⌘6 |
| Recognize text (OCR → clipboard) | ⇧⌘2 |
| Record screen / stop recording | ⇧⌘5 |

Conflicting macOS screenshot shortcuts are disabled while xShot runs (session only, restored on quit). Shortcuts can be changed in Settings.

After a capture, a Quick Access thumbnail shows in the bottom-left corner: copy, save, annotate, pin, OCR, or drag it into another app.
Recordings can be saved as MP4, GIF or both (Settings › Recording), and any MP4 recording can be turned into a GIF from its Quick Access thumbnail.
The editor's Background button (B) adds padding, rounded corners and a shadow on a gradient, solid, transparent or blurred-wallpaper backdrop, with optional 1:1 / 4:3 / 16:9 framing. Settings › 背景 can apply that background automatically to every capture or to window captures only; the editor can still adjust or remove it afterwards.

Capture history (menu bar › 截图历史…, optional shortcut in Settings) keeps a PNG copy and thumbnail of every screenshot in `~/Library/Application Support/xShot/History`, pruned after 1 day / 1 week / 1 month or kept forever. Recordings and GIFs are listed by file location only.
Editor tools: arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counter, pixelate, crop (shortcut keys V/A/L/R/O/P/H/T/N/X/C).

## Build

```sh
scripts/build.sh           # -> build/xShot.app
scripts/build.sh install   # install to /Applications and relaunch
```

Requires `xcodegen`. Set `XSHOT_SIGN_IDENTITY` to a code-signing certificate name (see `security find-identity -v -p codesigning`) so the screen-recording permission survives rebuilds; without it the app is signed ad-hoc.

## Releases

GitHub Actions (`.github/workflows/build.yml`) builds every push and pull request; the dmg/zip are attached to the run as artifacts. Pushing a `v*` tag also publishes a GitHub Release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Without signing secrets the release is signed ad-hoc, so macOS blocks the first launch (allow it under System Settings › Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/xShot.app`) and screen-recording permission has to be granted again after each update. To ship a signed, notarized build, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Developer ID Application certificate exported as .p12, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | Password of the .p12 |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID |
