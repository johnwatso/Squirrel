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

## UI audit fixes — 24 October 2026

- UPS load gauge: the percentage now sits large in the ring with the power
  beneath it, so the arc and the number match.
- Dashboard cards are 12 pt apart throughout (previously 9, 0 and 16 pt).
- Schedule editor: the Repeat pop-up that duplicated the preset buttons is
  gone. Card and tile subtitles describe the action ("Put the Mac to sleep")
  and never repeat its title, and Wake is worded the same in the list and editor.
- "Mac Protection" is now "macOS Connection". The menu line uses the Personal
  Hotspot symbol while macOS has the UPS and `personalhotspot.slash` while it
  doesn't (the plain symbol before macOS 15, where the slash doesn't exist). "Connected" (green) still requires macOS to see the UPS *and* a
  shutdown rule; other states read "Connected · no shutdown rule", "macOS
  can't see this UPS", "Not shared with macOS" and so on. "Shared with macOS"
  names the UPS's role, never its verified state. When sharing is off, the
  card offers "Share with macOS" (the same switch as Settings), and the menu
  shows the grey "Not shared with macOS" line instead of nothing.
- Debug tests: 134 passed. The dashboard and menu were captured on the
  isolated copy with sharing off. The schedule sheet was not captured.
- Measurement row: battery, runtime and load are centred columns, battery and
  runtime centre on the load ring, and the dividers run the row's height.
- Edit Schedule… is a standard push button, like Share with macOS.
- The UPS selector sizes to the name (140 pt minimum, truncating past 240 pt,
  or 150 pt in narrow windows). Manage UPS… lives only in the selector, as the
  reference layout specifies, not also in the ⋯ menu.
- One vocabulary for Squirrel's link to a UPS everywhere it appears:
  Connecting…, Not connected, Paused, Not monitoring.
- The Power Schedule sheet explains the two-slot limit once, behind its help
  button; the info box that repeated it is gone.
- Removed the unused `PowerManagementSection`.
- Text sizes come from `SquirrelFont`, a named scale at the existing sizes.
  macOS text styles were not used because they are fixed sizes that would
  shrink the 14 pt reference layout. The dashboard capture was pixel-identical
  before and after. The onboarding "Couldn't connect" title moved from 24 to
  26 pt to match the assistant's other titles.
- Debug tests: 136 passed.

## Telemetry composition — 24 October 2026

- Replaced the three gauges with a two-tier summary inside the existing device
  card. Battery has the largest value and a single 4 pt charge bar; runtime is
  text aligned with the device name above. A quieter demand row keeps UPS load
  and power together. Native macOS text styles establish the hierarchy.
- Normal load is monochrome; the battery bar retains its existing green,
  orange and red state colours. Stale readings are grey and explicitly labelled
  as last recorded. Runtime has no proportional graphic.
- Missing readings remain labelled as unavailable. The demand row can wrap into
  two lines when its contents need more width. Existing watts/VA formatting and
  telemetry calculations are unchanged, as are the surrounding dashboard sections
  and window dimensions.
- Debug build passed with no compiler warnings; all 136 existing tests passed.
  After the tests, final alignment and missing-power colour adjustments were
  rebuilt and visually checked.
- Inspected production telemetry views rendered with real reading/formatting
  code at 460, 682 and 1000 pt in light and dark appearances. Fixtures cover long
  runtimes, low battery, overload, stale values, missing readings, zero readings
  and apparent power. Minimum-width light/dark state sheets are saved as
  `Visual-Verification/telemetry-states-{light,dark}-460.png`.
- Inspected the built dashboard beneath its unchanged device header using an
  isolated app copy and loopback NUT fixture. Sharing with macOS, notifications
  and sleep prevention were disabled in that copy. The capture at the existing
  default size is `Visual-Verification/telemetry-dashboard-light.jpg`.

## Grouped telemetry refinement — 24 October 2026

- Matched the supplied render's grouping: battery and runtime share a larger
  rounded panel with a subtle state tint; UPS load has a separate, narrower
  neutral panel. The restored load ring is 84 pt, with percentage and power
  together inside. The primary battery bar is 6 pt tall.
- Panel fills use adaptive system control-background, foreground and semantic
  colours. Shared 12 pt outer padding and spacing keep the overall telemetry
  height slightly below the preceding two-tier layout. The device header and
  all other sections remain unchanged.
- Debug build passed without compiler warnings. Inspected production telemetry
  renders in light and dark mode at 460, 682 and 1000 pt, covering missing and
  stale readings, zero values, long runtimes, overload and apparent power.
  No telemetry calculation, communication or polling code changed.
- Verified the full built dashboard using the isolated loopback fixture app.
  Capture: `Visual-Verification/telemetry-grouped-dashboard-light.jpg`.
  Minimum-width state sheets:
  `Visual-Verification/telemetry-grouped-states-{light,dark}-460.png`.

## Otter toolbar alignment — 24 October 2026

- Adopted Otter's native ToolbarItemGroup and SF Symbols: gearshape for the
  settings/actions menu, clock.arrow.circlepath for Power History, and
  stethoscope for the existing connection assistant. Removed custom icon sizing
  and spacing so macOS supplies the same grouped toolbar appearance as Otter.
- Power Schedule remains in the gear menu and its dashboard section. Existing
  refresh, device editing and removal actions remain in the gear menu.
- Debug build passed without compiler warnings. Inspected the built toolbar and
  gear menu in the isolated fixture app; saved `Visual-Verification/otter-toolbar-light.jpg`.

## Restore the UPS sidebar — 24 October 2026

- Replaced the toolbar UPS selector and custom popover with a native
  NavigationSplitView sidebar. It opens visible, lists each UPS with its live
  status, and offers Add, Remove and Manage controls at the bottom. Device
  context menus retain the existing actions; the toolbar keeps gear/history.
- The sidebar uses a 200 pt ideal width with a 180–260 pt range. The dashboard
  retains its 460 pt minimum width and fits alongside the sidebar in the
  unchanged 682 pt default window. Native sidebar collapse/expand is available.
- Debug build passed without compiler warnings. In an isolated two-device
  fixture, selecting Office changed the header and readings to 75%, 30 min,
  6% load and 60 W. Hiding and reopening the sidebar preserved that selection.
  System sharing stayed disabled; selection does not change the shared UPS.
- Capture: `Visual-Verification/sidebar-restored-light.jpg`.

## Dedicated connection editor and reconnect recovery — 25 October 2026

- Connection actions in the dashboard, sidebar context menu and Manage UPS
  sheet now open a separate Connection window. Credential-repair actions use
  the same editor. Add UPS continues to use onboarding.
- Existing server, port, UPS and Keychain credentials populate a local draft.
  Test Connection enumerates the server and reads its UPS devices without
  saving, publishing or restarting monitoring. Save requires a changed draft
  matching the successful test and a selected UPS with a real reading.
- A missing original UPS requires an explicit selection. Empty servers,
  invalid fields, failed probes, edits after testing, cancellation, duplicate
  targets, removed devices and concurrent connection changes cannot apply an
  unverified draft. Saving preserves the current name, picture, polling interval
  and sharing role; credentials move to the new Keychain account when necessary.
- The window sizes to its content, including authentication and error messages.
  In the isolated loopback fixture, verified opening, cancellation, successful
  testing, authentication expansion and saving a changed port. Read back the
  isolated settings to confirm the port changed while the same UPS and sharing
  role remained. Captures: `Visual-Verification/connection-editor-light.jpg`
  and `Visual-Verification/connection-editor-tested-light.jpg`.
- The supplied log exposed reuse of a dead NUT socket after a server reset.
  Failed polls now abort that transport before retrying; stopping monitoring
  also aborts pending transports. The editor probe has a bounded timeout and
  cancellation that aborts its own temporary client.
- All 143 tests passed, including six editor regression tests and a loopback
  monitor test that drops the first live connection and verifies a fresh socket
  supplies the recovered reading. Final Debug build passed without compiler
  warnings after accessibility-label adjustments. Test linking retains the
  existing XCTest SDK macOS-14 versus app deployment-target-13 warnings.
- macOS's `com.apple.linkd.autoShortcut` service errors also occurred in the test
  host; they are separate from the closed-socket failure and are not resolved
  by this change. No system service or live UPS configuration was changed.

## Right-aligned UPS illustration — 25 October 2026

- Moved the illustration to the trailing edge of the device header. Name,
  manufacturer/capacity and status now share the Battery section's leading
  alignment. Illustration width reduces from 115 to 88 pt in narrower detail
  panes; the header retains its existing minimum height.
- Kept the picture picker and exposed it as a separate accessible button.
  Verified the built app with the sidebar visible and collapsed, and opened
  the picker from the relocated image. Debug build passed without warnings.
- Capture: `Visual-Verification/header-illustration-right.jpg`.
