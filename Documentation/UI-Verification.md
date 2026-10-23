# UI refinement verification — 22 October 2026

- Xcode Debug and Release builds: passed, with Sparkle embedded in the app bundle.
- Xcode tests: 102 passed, zero failures. New regression coverage checks expired
  readings, missing measurements, explicit menu values, apparent-power units,
  Sparkle configuration validation, and separation of samples/events by UPS ID.
- Light appearance: inspected a single UPS at the new default 500 × 620 pt size,
  sidebar hidden and visible, and expanded Technical Information with scrolling.
- Dark appearance: inspected multiple devices, selected-device highlighting,
  connecting and disconnected states, and useful messages without borrowed data.
- Empty configuration: inspected onboarding and the main no-UPS state.
- Updates: verified the application-menu action and native unavailable alert
  when no Squirrel feed/key is configured. Actual release installation remains
  pending the first signed release and published appcast.
- Live UPS: verified the refined app still reads the existing UPS and macOS
  reports it at 100% on AC power. Inspected the real sleep/shutdown/restart rows
  and recognition indicator. No outage or shutdown test was performed.
- Native menu measurements are covered by presentation tests and use the same
  observed monitor state as the main view; no separate NUT polling was added.

Visual edge-state checks used temporary, separately identified app copies and a
loopback NUT fixture, with publishing and notifications disabled. Their settings
and history were isolated from the live app and cleaned up afterward. Production
code contains no synthetic UPS readings or events. Light mode was forced only
for the temporary copy; the system appearance was not changed.

## Power scheduling and dashboard refinement — 23 October 2026

- Debug tests: 111 passed, zero failures. Added coverage for system schedule
  parsing, exact custom weekday masks, invalid recurring combinations, disabled
  rule persistence, stale edits after app activation, system readback, exclusive
  Mac protection selection, and honest history provenance.
- Universal Release build: passed for arm64 and x86_64, without new compiler
  warnings. Debug test linking retains the SDK's XCTest macOS 14 versus app
  deployment-target 13 warnings; the deployment target was not raised.
- Isolated app copy: inspected the native schedule sheet, add-rule menu, time
  picker, weekday toggles, Cancel and inactive Apply before edits. No schedule
  was applied and no authentication prompt was invoked.
- Read-only system inspection: the Apple silicon macOS 27.0.1 host returned no
  scheduled events and reported autorestart support. New history event types do
  not infer successful power operations from missing telemetry.
- Visual checks: light and dark dashboard, native schedule sheet, General and
  Power settings tabs, populated history sheet, and a 460 pt minimum-width
  dashboard with scrolling and toolbar overflow. The original system Auto
  appearance setting was restored after inspecting Dark.
- Multi-UPS selection: a temporary loopback NUT fixture supplied separately
  identified Rack/Office readings. Selecting Office changed its displayed
  capacity/power/load without changing the protection designation. Native UPS
  publishing, sleep prevention and notifications were disabled in the isolated
  copy. The production app and its configuration were not replaced.
- Live hardware protection and schedule execution were not exercised. The
  fixture validates monitoring/UI behaviour, not an actual outage or reboot.
  See Power-Scheduling.md for interfaces, preservation rules and acceptance
  tests that still require physical hardware.
