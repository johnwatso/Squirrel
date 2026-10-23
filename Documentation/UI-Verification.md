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

## Power Schedule redesign — 23 October 2026

- Replaced the inline technical editor with a content-sized card list and a
  separate Add/Edit sheet, following the supplied visual reference. The two
  real macOS recurring slots replace the reference's illustrative three rules.
- Debug build and all 132 tests passed. Release build passed; no new Release
  compiler warnings. Tests cover recurrence masks, occupied-slot selection,
  disabled-only edits without authorization, cancellation/retry, failed readback
  without committing local drafts, deletion preserving the other rule, and
  external active rules taking precedence over disabled drafts.
- Inspected the production SwiftUI views in a temporary preview application with
  an injected, in-memory schedule writer and separate UserDefaults suite. No real
  pmset write, administrator prompt or hardware power event was triggered.
- Verified light/dark card lists and editors, the empty state, all four action
  tiles, free-slot selection, edit/save, disable, delete, and disabled creation.
  Custom weekday selection with zero days disables Add. Verified the native repeat
  pop-up opens from the right-hand arrow and updates the matching preset pill.
- Native date fields, switches and menus retain their system behaviour. The
  editor fits its content and scrolls when custom days or errors need more space.
  The native controls may appear inactive in captured previews.
- Standard Additions authentication prompt syntax compiled successfully without
  executing it. Actual authentication approval/cancellation, system persistence,
  wake from sleep, startup from shutdown, and firmware-specific behaviour remain
  physical acceptance tests as described in Power-Scheduling.md.
- Captures: `Visual-Verification/power-schedule-{light,dark,empty,add}.png` and
  `Visual-Verification/power-schedule-editor-{light,dark}.png`. The preview
  fixtures and their harness are not included in production sources.

## Menu bar redesign — 23 October 2026

- The menu moved from SwiftUI's menu-style `MenuBarExtra` to an AppKit
  `NSStatusItem` and `NSMenu` (`MenuBarMenu`). On macOS 27, SwiftUI's menu drops
  symbol colours, attributed titles and tab stops, and greys every read-only
  row, so it could not show a coloured status or right-aligned readings. A
  never-inserted `MenuBarExtra` stays as the first scene so no window opens at
  launch, and an invisible SwiftUI view hosted in the status item keeps window
  opening and first-run setup on `openWindow`.
- Read-only rows (UPS name, power status, Battery / Runtime / UPS Load, Mac
  protection) are small item views: AppKit dims disabled native items whatever
  their colours. Actions stay native items, so highlighting, separators and
  key equivalents (⌘O, ⌘Y, ⌘, and ⌘Q) are the system's own.
- The initial pass assigned template action images but macOS 27.0.1 hid them
  by default. The polish pass below explicitly requests native image visibility.
  Only status symbols carry colour.
- The status item is a template SF Symbol that changes shape for warnings
  (battery level, triangle, slashed bolt), never colour.
- "Mac protected" appears only when `MacProtectionStatus` is active (macOS
  recognises the UPS and a shutdown rule is set), never because a UPS is connected.
- Debug tests: 134 passed. Presentation tests cover status symbols and tones,
  the combined load row, missing readings, and the protection wording.
- Visual checks: light and dark, on a separate Debug copy with publishing and
  notifications off (`menu-bar-light.png`, `menu-bar-dark.png`). Disconnected,
  battery and multi-UPS states were checked through tests only, because the
  copy shares the live app's history database.

### Capturing the menu without driving the menu bar

Debug builds accept two argument-domain flags. `-SquirrelOpenMenuAtLaunch YES`
opens the menu three seconds after launch, and `-SquirrelMenuAppearance Dark`
(or `Light`) forces the menu's appearance without changing the system's.
Capture the menu's screen region (`screencapture -R`) rather than its window
(`-l`): a window capture has no backdrop, so vibrant text looks wrong.

The `-preferences` override must be property-list data, with angle brackets:
`-preferences "<7b22…7d>"`. A bare hex string is read as text, decodes to
nothing, and the copy falls back to default preferences, which publish to macOS.

## Menu bar polish — 23 October 2026

- Kept the existing AppKit menu, grouping, row heights, action destinations and
  keyboard equivalents. Added a 270 pt native minimum width; AppKit remains
  free to expand for longer content. The device heading is one point larger,
  still semibold; telemetry labels now use adaptive label colour for contrast.
- Action images use menu-sized monochrome SF Symbols and the native image
  column. `preferredImageVisibility = .visible` is guarded by macOS 27
  availability. Apple's installed CoreGlyphs availability catalogue dates all
  seven requested action symbols to macOS 10.15 or 11, before the Ventura target.
- Debug build and all 134 tests passed. Universal Release build passed for
  arm64 and x86_64 with no compiler warnings. Ventura itself was not available
  for a runtime check.
- An isolated preview compiled the production menu implementation with fixture
  rows, separate app defaults and in-memory history. Monitoring, publishing and
  app startup services were never started. Verified light/dark contrast, green
  mains/protection symbols, orange battery/warning symbols, red critical symbols,
  right-aligned readings, and native action icon/shortcut alignment.
- Measured the standard fixture at 270 × 337 pt, a long-name fixture at
  328 × 337 pt, and unavailable telemetry at 350 × 299 pt. Long names truncate
  without overlapping other content; production headings expose their full
  name in a tooltip and accessibility label. Missing telemetry remains omitted.
- The preview dispatched ⌘O, ⌘Y, ⌘, and ⌘Q through native key equivalents to
  recording closures, avoiding real actions. Opened Controls and verified arrow
  keys move the native selection from Refresh Now to Pause Monitoring.
- Repeated telemetry refreshes during native menu tracking retained identical
  menu items and views and an unchanged 270 × 337 pt menu frame. The menu stays
  open and readings remain aligned; shorter readings no longer reset row width.
- Captures: `Visual-Verification/menu-polish-{light,dark,long-name,unavailable,
  battery,critical,controls}.png`. These show isolated fixtures, not live UPS
  measurements; fixture code was not added to production sources.
