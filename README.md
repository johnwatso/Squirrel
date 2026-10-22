<p align="center">
  <img src="Squirrel.icon/Assets/289df51d-cacd-437b-9536-307c1fa5006d.png" width="160" alt="Squirrel app icon">
</p>

<h1 align="center">🐿️ Squirrel</h1>

<p align="center"><strong>A network UPS that feels plugged into your Mac.</strong></p>

<p align="center">
  A native macOS menu bar app that monitors your UPS through Network UPS Tools (NUT) and presents it to macOS as a system power source.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013+-blue" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/interface-SwiftUI-orange" alt="Built with SwiftUI">
</p>

Squirrel connects to the NUT server on your NAS, server, or another computer attached to a UPS. It brings battery charge, remaining runtime, and power state into a quiet menu bar app—and lets macOS see the UPS through its own power-management system.

With system integration enabled, you can use the Mac's native UPS shutdown settings and inspect the power source with `pmset`. Squirrel also shows whether macOS recognises the UPS and whether shutdown rules are configured.

## Why “Squirrel”?

Squirrels collect NUTs and keep something in reserve for when they need it. This one keeps an eye on your reserve power.

## Features

- 🔋 Battery charge, estimated runtime, load, and other telemetry when reported by your UPS
- 🍎 System power-source integration for native macOS UPS recognition and shutdown settings
- 🧭 A connection assistant that discovers NUT servers, lists their UPSes, and verifies that macOS sees the selected device
- 🖥️ Monitoring for multiple UPSes, with one selected to supply the Mac's system power source
- 📈 Local power history and an event timeline for outages, low battery, and connection changes
- 🔔 Configurable notifications for power changes, low battery, and connection problems
- 💤 An option to prevent idle system sleep during an outage so the Mac can reach its shutdown threshold
- 🔐 Optional NUT authentication, with passwords stored in macOS Keychain
- ⏸️ Pause and resume controls, launch at login, and configurable menu bar battery display
- 🔗 Shortcuts actions for UPS status, battery level, the Mac's power source, and monitoring controls
- ⌨️ A bundled `squirrelctl` command for local shell automation

## How it works

Squirrel polls the configured NUT servers and publishes the selected UPS to macOS through IOKit. macOS owns the shutdown policy; Squirrel supplies the power readings and shows the current settings. Short on-battery transitions are debounced, while low-battery and forced-shutdown states bypass that delay. Readings that become stale stop being presented as a connected UPS.

System integration uses IOKit functions that Apple ships but does not document in public headers. Squirrel checks for them at runtime and falls back to monitoring when integration is unavailable. Recognising a UPS and having shutdown rules configured do not prove that a shutdown has been tested during an outage.

Squirrel runs in your logged-in session and must remain running to publish the power source. Pausing or quitting removes that source from macOS.

## Using Squirrel

1. Open Squirrel and follow the connection assistant.
2. Choose a discovered NUT server, or enter its hostname or IP address and port. The default NUT port is `3493`.
3. Add credentials if your server requires them, then select a UPS from the live list.
4. Review the connection result and confirm that macOS recognises the UPS.
5. Review **Mac Protection** and configure your preferred shutdown thresholds in macOS's UPS settings.

You can add more UPSes later and choose which one supplies the Mac's system power source. Other configured UPSes remain available for monitoring.

## Requirements

- macOS 13.0 or later
- A reachable NUT server serving your UPS, with this Mac allowed to connect
- Local Network access when requested by macOS

The current client connects over plain TCP; STARTTLS is not implemented. Use a trusted network or a protected connection such as a VPN when accessing a remote server.

## Building

Open `Squirrel.xcodeproj` in a recent Xcode with Swift 6 and Icon Composer `.icon` support, select the `Squirrel` scheme, and run. Sparkle is fetched automatically through Swift Package Manager.

```sh
open Squirrel.xcodeproj
```

Run the tests with:

```sh
xcodebuild test -project Squirrel.xcodeproj -scheme Squirrel -destination 'platform=macOS'
```

The project is generated from `project.yml`. If you change project configuration, update that file and regenerate with XcodeGen:

```sh
xcodegen generate
```

For interface checks, see the [UI verification guide](Documentation/UI-Verification.md). Sparkle integration is included, but development builds leave the update feed and signing key unset; see [update configuration](Documentation/Updates.md) for release setup.

## Command line

The built app includes `Squirrel.app/Contents/MacOS/squirrelctl`. It communicates with the running app through macOS distributed notifications and opens no network port.

```sh
SQUIRRELCTL="/Applications/Squirrel.app/Contents/MacOS/squirrelctl"
"$SQUIRRELCTL" status
"$SQUIRRELCTL" system
"$SQUIRRELCTL" refresh
"$SQUIRRELCTL" pause
"$SQUIRRELCTL" resume
"$SQUIRRELCTL" version
```

To inspect the power sources macOS itself reports:

```sh
pmset -g ps
```
