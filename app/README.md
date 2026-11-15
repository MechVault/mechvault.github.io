# MechVault for Windows, macOS and Linux

The cross-platform version of MechVault: .NET 10 + Avalonia, one codebase. It reads the same `calc/*.json` and `lang/*.json` files as the PowerShell app and keeps user data in the same JSON format.

| Folder | What it is |
| --- | --- |
| `src/MechVault.Core` | Logic without UI: calculator, Crate Rush, rates, goals, accounts, ratings, misread protection, currency-bar detection, updater, wiki refresh |
| `src/MechVault.App` | Avalonia app: windows, overlay, tray, screen reading per OS (`Platform/`) |
| `tests/MechVault.Tests` | xUnit tests; `reference/` holds the output of `MechVault.ps1 -SelfTest` (English) that the C# code must reproduce |
| `macos/` | `mvhelper.swift` (window capture + Apple Vision text recognition) and `Info.plist` for `MechVault.app` |
| `linux/` | desktop entry |

## Build and test

```bash
dotnet test app/tests/MechVault.Tests
dotnet run --project app/src/MechVault.App
```

`MechVault --probe` finds the game and reads both balances once, without opening the app or touching any data.

The GitHub workflow `.github/workflows/build.yml` builds and tests on Windows, macOS and Ubuntu and packages `MechVault-win-x64.zip`, `MechVault-osx-arm64.zip`, `MechVault-osx-x64.zip` (with `MechVault.app`) and `MechVault-linux-x64.tar.gz`. A tag `app-v<version>` attaches them to a GitHub Release; the website links to the latest one.

## Where data lives

- Windows: the `dati` folder next to `MechVault.exe`, as in the PowerShell app. Put the new app in the same folder as the old one and it uses the same accounts, goals and settings.
- macOS: `~/Library/Application Support/MechVault`
- Linux: `$XDG_DATA_HOME/MechVault` (usually `~/.local/share/MechVault`)

## Automatic reading per OS

Only pixels of the game window are read, like a screenshot. Nothing touches the game's memory or files, and nothing is ever sent to the game.

- Windows: Mech Arena process (`mech.?arena`), window captured with `PrintWindow`, text read by Windows OCR.
- macOS: the Mech Arena app started by Plarium Play. `mvhelper` captures its window (ScreenCaptureKit) and reads it with Apple Vision. macOS asks for the Screen Recording permission (System Settings › Privacy & Security › Screen & System Audio Recording).
- Linux: the Wine/Proton process, X11 window captured with `XGetImage`, text read by Tesseract (`tesseract-ocr` package). On Wayland automatic reading is off and balances are entered by hand.

## macOS: unsigned app

Without an Apple Developer ID the app is only ad-hoc signed. The first time, right-click `MechVault.app` › Open › Open.

## Updates

The app reads `https://mechvault.github.io/version.json`. The PowerShell fields stay as they are; the new app only looks at `platforms.<rid>` (`win-x64`, `osx-arm64`, `osx-x64`, `linux-x64`), each with `version`, `url` (https) and `sha256`. A package is installed only when it is newer and its SHA-256 matches; the data folder is never touched. Until those entries exist, the app reports that it is up to date.
