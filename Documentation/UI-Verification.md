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
