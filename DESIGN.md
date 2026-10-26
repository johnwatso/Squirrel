# Squirrel — design investigation

A native macOS menu bar app that makes a **network UPS behave like a USB UPS**.
Squirrels hoard **NUT**s.

Status: the investigation below became Squirrel, which now ships this design. Kept as the
record of why it works this way. Last updated 2026-10-27.

---

## 1. Verdict

Yes, and the opening is exactly the gripe: *Nutty feels like a shortcut maker for a
network UPS, not like a UPS.*

That feeling is not subjective. It is a verifiable architectural fact, and it is fixable.
macOS has one and only one mechanism by which any UPS — USB or otherwise — becomes
visible to the system. **Nutty does not use it. We can.**

Squirrel's thesis in one line:

> Don't show the user a UPS dashboard. Hand macOS a UPS.

Everything else (menu bar polish, onboarding, notifications) is table stakes we get
nearly for free by copying Otter's patterns. The power source is the product.

---

## 2. Why Nutty feels like a shortcut maker

Inspected `/Applications/Nutty.app` (v6.08.21, native SwiftUI + Sparkle, macOS 15+):

| Check | Result |
|---|---|
| `nm -u` for `IOPS*` / `IOPM*` imports | **none** |
| Links IOKit | only `libswiftIOKit.dylib`, weak |
| Shutdown mechanism (`strings`) | `sudo /sbin/shutdown -h now` |
| What it asks the user to do | `yourusername ALL=(ALL) NOPASSWD: /sbin/shutdown` |
| Failure string it ships | *"Forced shutdown failed. Configure passwordless sudo for /sbin/shutdown (NOPASSWD), or the Mac may not power off during an outage."* |

So Nutty:

- never publishes a power source → **macOS does not know a UPS exists**. System Settings
  shows nothing, `pmset -g ps` shows nothing, no other app or script can see it.
- never takes a power assertion → its own docs admit that if the Mac is asleep when a
  rule fires, it stays asleep and shuts down nothing.
- performs shutdown by shelling out to `sudo`, which means **asking the user to edit
  `/etc/sudoers`** for the app's single most important function.
- reimplements, in app-level "shutdown rules", a policy engine macOS already ships.

That is the whole feeling, explained. A UPS that needs a sudoers entry is a shortcut with
a UI on it. The animation jank is a symptom; this is the disease.

---

## 3. The mechanism (verified, with evidence)

Three IOKit functions:

```c
IOReturn IOPSCreatePowerSource(IOPSPowerSourceID *outPS);
IOReturn IOPSSetPowerSourceDetails(IOPSPowerSourceID ps, CFDictionaryRef details);
IOReturn IOPSReleasePowerSource(IOPSPowerSourceID ps);
```

Confirmed on this machine (Mac mini M1, macOS 27.0.1, Xcode SDK 27.0):

1. **They are linkable exports, not a dlsym-only hack.** All three appear in
   `MacOSX27.0.sdk/.../IOKit.framework/Versions/A/IOKit.tbd`. They are absent from the
   public `IOPowerSources.h` header — declared, shipped and linkable, but undocumented.
2. **Apple's own UPS daemon uses exactly these three.** `nm -u /usr/libexec/ioupsd`
   imports `_IOPSCreatePowerSource`, `_IOPSSetPowerSourceDetails`,
   `_IOPSReleasePowerSource` and nothing else from that family. This is the key insight:
   a USB UPS is not special to macOS. `ioupsd` reads HID Power Device usages off USB and
   then calls these functions. **USB is just ioupsd's data source.** We have a different
   data source (NUT) and the same destination.
3. **It works from an ordinary app.** A probe run as `john` (uid 501) — unsigned,
   unentitled, not root — returned `kIOReturnSuccess` from both calls, and from a
   *separate* process:

   ```
   $ pmset -g ps
   Now drawing from 'AC Power'
    -Squirrel Probe UPS (id=-1682303766)  100%; AC attached; not charging present: true
   ```

   `IOPSReleasePowerSource` removed it cleanly. No kext, no DriverKit entitlement, no SIP
   change, no helper.
4. **It works signed, with the hardened runtime.** Re-signed `--options runtime`
   (`flags=0x10002(adhoc,runtime)`) and re-run: identical success, still visible in
   `pmset -g ps`. Release signing does not close this door. (§7 has the sandbox result,
   which is the one case that *does* fail.)
5. **macOS presents it as a real UPS in System Settings.** With the probe publishing,
   System Settings → Energy showed `UPS Level: 100%` in the pane header and a
   **UPS Options…** button. The sheet behind it is titled **UPS Model: UniFi UPS 2U** —
   our published `Name`, verbatim — with all three native shutdown controls live:

   | Control in the sheet | Writes |
   |---|---|
   | *Shut down your Mac after using the UPS Battery for:* (1–15 min) | `haltafter` |
   | *Shut down your Mac when the time remaining on UPS battery is:* (1–15 min) | `haltremain` |
   | *Shut down your Mac when the UPS battery level is below:* (0–100%) | `haltlevel` |

   That is the Energy pane a USB UPS produces, driven entirely by an unprivileged
   userspace publisher. Screenshots: `research/evidence-energy-pane.jpg`,
   `research/evidence-ups-options.jpg`.
6. **Apple anticipated network UPSes.** `IOPSKeys.h` documents
   `kIOPSNetworkTransportType = "Ethernet"` alongside USB and Serial as transports that
   *"usually describe UPS's"*, and `kIOPSUPSType = "UPS"` as a power source type. We are
   not abusing the API; we are using a case it was written for.

Both probes are kept in `research/` (`psprobe.c`, `SwiftProbe.swift`) — rerun any time.

**One trap in the Swift binding.** `IOPSCreatePowerSource` hands back an
`IOPSPowerSourceID`, which is an opaque pointer and *not* a CoreFoundation object.
Declaring the `@convention(c)` signatures in terms of `CFTypeRef` puts the handle under
ARC, and the first retain or release of it segfaults — reliably, the moment a reading is
published. Carry it as `UnsafeMutableRawPointer` and let `IOPSReleasePowerSource` be the
only thing that frees it. Verified on macOS 27.0.1: with `CFTypeRef`, `SwiftProbe` prints
both success codes and then dies with SIGSEGV; with the raw pointer, all three calls
return 0 and the process exits cleanly.

Prior art worth reading: [`jamesarm97/macos-ups-glitch-filter`](https://github.com/jamesarm97/macos-ups-glitch-filter)
seizes a flaky USB UPS with `kIOHIDOptionsTypeSeizeDevice`, debounces it and republishes
a clean source through these same calls — and reports the battery menu and System
Settings UPS controls keep working off the republished data. An existence proof of the
second half of the claim from a source other than our own probe.

### Keys to publish

| Power source key | Literal string | From NUT |
|---|---|---|
| `kIOPSNameKey` | `Name` | `device.model` / user's label |
| `kIOPSTypeKey` | `Type` | always `"UPS"` |
| `kIOPSTransportTypeKey` | `Transport Type` | always `"Ethernet"` |
| `kIOPSPowerSourceStateKey` | `Power Source State` | `OL`→`"AC Power"`, `OB`→`"Battery Power"` |
| `kIOPSCurrentCapacityKey` | `Current Capacity` | `battery.charge` — drives `haltlevel` |
| `kIOPSMaxCapacityKey` | `Max Capacity` | 100 |
| `kIOPSTimeToEmptyKey` | `Time to Empty` | `battery.runtime` (s→min) — drives `haltremain` |
| `kIOPSIsPresentKey` | `Is Present` | driver connected && data fresh — **false, don't lie, when stale** |
| `kIOPSIsChargingKey` | `Is Charging` | `CHRG` in `ups.status` |

---

## 4. What this buys

Publishing one dictionary turns on, for free, everything Nutty rebuilds by hand:

- **System Settings → Battery/Energy UPS controls become real.** The user's own
  thresholds, in Apple's UI, not ours.
- **`pmset -u haltlevel / haltafter / haltremain`** — `powerd` performs the emergency
  shutdown itself. No sudoers entry. No `/sbin/shutdown`. No shutdown-rule engine in our
  app at all. The biggest single deletion of both code and user friction.
- **The menu bar battery item** shows the UPS, as with a USB unit.
- **macOS switches to its UPS Power settings profile** on battery, automatically.
- **Every other app and script on the box sees it** — `pmset -g ps`, monitoring agents,
  anything calling `IOPSCopyPowerSourcesInfo`. A network UPS stops being one app's
  private knowledge.

Squirrel's UI can therefore be *smaller* than Nutty's. We delete the shutdown-rules
screen and link to System Settings instead.

### A trap worth catching early

This machine's UPS Power profile is currently `sleep 1`, `displaysleep 2`. The moment a
UPS power source goes to Battery Power, macOS applies that profile — so an idle Mac mini
would sleep **one minute** into an outage, and a sleeping Mac may never reach its halt
threshold. Nutty hits this too; its answer is "go configure Energy Saver yourself."

Squirrel's answer:

- surface the UPS-profile sleep timers in our own UI, read via `pmset -g custom`, and
  offer to fix them; and
- hold an `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` for
  as long as the UPS is on battery, releasing it on line-power restore.

A USB UPS owner never thinks about this. Neither should ours.

---

## 5. The one thing still unproven

macOS *offers* the native shutdown controls for a published source and labels them with
our UPS's name (§3.5), and those sliders write `haltafter` / `haltremain` / `haltlevel`.
What that does not prove is that `powerd` **executes** the shutdown when a threshold is
crossed, because `man pmset` carries this caveat:

> Note: None of these settings are observed on a system with support for an internal
> battery, such as a laptop. UPS emergency shutdown settings are for desktop and server
> only.

For this Mac mini the evidence says we are on the right side of that line — `pmset -g batt`
reports no internal battery power source — but it is not clean: the M1 mini *does* expose a
stub `AppleSmartBattery` IOKit node with `MaxCapacity = 0`. Whether `powerd` counts that
when deciding to honour `haltlevel` cannot be read off the system. The only way to find
out is to let it fire.

**Prove it deliberately, before building anything else.** About 10 minutes:

```bash
sudo pmset -u haltafter 1          # shut down 1 min after going on UPS battery
pmset -g ups                       # confirm it stuck
```

then run a build of the probe that publishes `Power Source State = "Battery Power"`, and
watch whether the Mac powers off about a minute later. Save your work first — a pass
means it shuts down. Reset with `sudo pmset -u haltafter 0`.

Two more things the same drill settles:

- whether a **non-root** publisher is honoured for shutdown policy (visibility is proved;
  halt policy is not — `ioupsd` runs as root). If root turns out to be required, the
  LaunchDaemon in §8 stops being optional.
- how fast `powerd` reacts, which sets the debounce budget.

If the drill fails, Squirrel still wins on the power source for *display* and keeps an
app-level shutdown path — but it should then use a privileged helper doing a proper
authenticated shutdown, never a sudoers entry.

---

## 6. Platform and minimum OS

**Decided: `MACOSX_DEPLOYMENT_TARGET = 13.0` — Ventura and newer.** Swift 6, 100% Swift.

That is the true floor for this feature set, taken from the SDK's own availability
annotations rather than from memory:

| API we need | Introduced |
|---|---|
| `MenuBarExtra`, `.menuBarExtraStyle(.menu)` | **macOS 13.0** |
| `AppIntent`, `AppEntity`, `EntityStringQuery`, `AppShortcutsProvider` | **macOS 13.0** |
| `SMAppService` (launch at login) | **macOS 13.0** |
| `openWindow` / `Window` scene | macOS 13.0 |
| `Settings` scene | macOS 11.0 |
| Sparkle 2.9.4 (`platforms: [.macOS(.v10_13)]`) | macOS 10.13 |
| `IOPSCreatePowerSource`, `IOPMAssertionCreateWithName`, `Network.framework` | far older |

So App Intents and `MenuBarExtra` set the floor together at 13.0, and nothing in the
design reaches past it.

**Why go lower than Otter's 15.0 rather than matching it.** Squirrel's user is not
Otter's user. `man pmset` restricts native UPS halt settings to machines with no internal
battery — so our entire native-integration story targets **always-on desktop Macs**, and
those are exactly the machines people deliberately leave on an older macOS: the Mac mini
in a rack, the 2017 iMac as a home server, the 2013 Mac Pro. Dropping from 15.0 to 13.0
costs us little and picks up precisely our audience. For contrast, NutBar (the App Store
competitor) requires macOS 26 and gives up most of this market for nothing.

**What 13.0 costs us.** Avoid `@Observable` (macOS 14) and `ContentUnavailableView`
(macOS 14), and the two-argument `onChange(of:initial:)`. All cheap — Otter already uses
`ObservableObject` + `@StateObject`/`@EnvironmentObject` throughout, so the pattern we are
copying is already 13-compatible. Gate anything newer behind `if #available`, e.g. a
Control Center `ControlWidget` (macOS 15) as a later nicety.

*(Considered and rejected: 14.0 for `@Observable`, 15.0 to match Otter. Ventura wins on
reach into exactly our audience.)*

**One thing to verify when the project first builds:** `actool` is reported to generate a
backwards-compatible `.icns` from a `.icon` file, with the deployment target deciding
which fallbacks it emits — but the reports are anecdotal and early Xcode 26 betas broke
icons on older systems. Build once at 13.0 and confirm the icon renders on a Ventura VM
before promising 13.0 publicly.

---

## 7. Signing, distribution, and "100% Swift"

### Signing

Release builds are signed, so the question is whether that breaks anything. It does not,
with one exception:

| Configuration | Result |
|---|---|
| Unsigned, non-root | **works** |
| Ad-hoc signed + `--options runtime` (hardened runtime) | **works** |
| Signed + `com.apple.security.app-sandbox` | **fails** — process killed, power source never appears |

The App Sandbox case is fatal, which settles distribution: **Developer ID + notarisation,
never the Mac App Store.** That is already where ShipHook points — its README states it
expects `Developer ID Application` signing for Sparkle-distributed apps — and the
undocumented symbols would fail App Store review regardless. No conflict: Otter's exact
pipeline works unchanged.

Target config, following Otter:

```
MACOSX_DEPLOYMENT_TARGET = 13.0
SWIFT_VERSION            = 6.0
ENABLE_HARDENED_RUNTIME  = YES
PRODUCT_BUNDLE_IDENTIFIER = io.github.johnwatso.Squirrel
ASSETCATALOG_COMPILER_APPICON_NAME = Squirrel
```

`Squirrel.entitlements` — **no** `app-sandbox`, and simpler than Otter's (we need no
location, since we never read Wi-Fi names):

```xml
<key>com.apple.security.network.client</key><true/>
<!-- Declared for explicitness; only takes effect under the App Sandbox, which Squirrel does not use. -->
```

`Info.plist`:

```
LSUIElement                     = true          menu bar only, no Dock icon
LSMinimumSystemVersion          = 13.0
CFBundleIconName                = Squirrel
LSApplicationCategoryType       = public.app-category.utilities
NSLocalNetworkUsageDescription  = "Squirrel needs local network access to reach your UPS's NUT server."
NSAppTransportSecurity          = { NSAllowsLocalNetworking = true }
NSSupportsAutomaticTermination  = false         ← a terminated Squirrel is a vanished UPS
NSSupportsSuddenTermination     = false         ← ditto
SUFeedURL / SUPublicEDKey / SUEnableAutomaticChecks
```

The two termination keys matter more here than in Otter: the power source dies with its
publishing process, so letting macOS reap Squirrel while idle removes the Mac's UPS.
Pair them with `ProcessInfo.processInfo.disableAutomaticTermination(…)` in code, as Otter
does, because a stale copy in `/Applications` still carries the old plist.

### Publishing

ShipHook, as with Otter: it watches the repo, builds, signs, notarises, then runs
`publish_sparkle_release.sh` to push the artifact and update `appcast.xml` on GitHub
Pages. Sparkle 2.9.4 via SPM, `SUFeedURL` pointing at the Squirrel site's appcast. Nothing
Squirrel-specific — but note ShipHook tags its own appcast commits `[shiphook skip]`, so
don't hand-edit the appcast.

### 100% Swift

Achievable with no C target and no bridging header. Two details, both proved by
`research/SwiftProbe.swift`:

1. **The functions** resolve through `dlopen`/`dlsym` and are called as
   `@convention(c)` pointers. Prefer this over `@_silgen_name`, which is unsupported and
   can break between toolchains. Direct linking also works (the symbols are in the
   `.tbd`) but needs a module map or shim header, which is what we're avoiding.
2. **The key constants do not bridge.** `kIOPSNameKey` and friends are C preprocessor
   `#define`s, so they are invisible to Swift. The literal strings are the contract —
   hoist them into one `enum PSKey` as in the probe, and unit-test that the published
   dictionary round-trips through `IOPSCopyPowerSourcesInfo`.

Wrap all three calls in one `PowerSourcePublisher` actor so the unsafe surface is about
40 lines, in one file, behind a protocol with a test double.

---

## 8. Architecture

Mirror Otter: Swift 6, SwiftUI `MenuBarExtra`, `App/ Models/ Views/ Services/`,
protocol-fronted services with test doubles, Sparkle, `squirrelctl`, ShipHook, website.

```
Squirrel/
  App/            SquirrelApp.swift, AppModel.swift, SquirrelShortcuts.swift
  Models/         UPSDevice, UPSStatus, UPSReading, AppPreferences
  Services/
    NUTClient.swift            line protocol over Network.framework
    NUTDiscoveryService.swift  find servers, LIST UPS
    PowerSourcePublisher.swift the whole point — the IOPS* actor
    PowerProfileAdvisor.swift  reads pmset -g custom, flags bad UPS sleep timers
    SleepAssertionService.swift
    CredentialStore.swift      Keychain, as Otter
    NotificationService.swift
    UPSEventLog.swift
  Views/          MenuBarView, UPSDetailView, OnboardingView, PreferencesView
SquirrelCLI/      squirrelctl
Squirrel.icon     Icon Composer (rename from squirrel.icon for consistency with the target)
```

### The one real architectural decision: daemon or not?

A USB UPS protects the Mac at the login window, during an OS update, with nobody logged
in. A menu bar app does not run then. And since the power source dies with its publishing
process, **if Squirrel crashes mid-outage macOS loses the UPS.** Full parity therefore
wants a `LaunchDaemon` (root, `SMAppService.daemon`, macOS 13+) owning the NUT connection
and the power source, with the GUI as an XPC client — structurally what `ioupsd` is.

Against it: Otter's "no helper daemon, no fuss" is a real selling point, and a daemon
means more install friction and a harder notarisation story.

**Recommendation:** ship v1 publishing from the app — ~90% of the value at zero install
friction, and the probes prove it works unprivileged and signed. But build `NUTClient` and
`PowerSourcePublisher` as a **dependency-free module with no AppKit imports**, so lifting
them into a daemon in v1.1 is a move, not a rewrite. Revisit immediately if the §5 drill
says root is required for halt policy.

---

## 9. NUT client

Trivial over `Network.framework`: ASCII, line-oriented, TCP 3493, `\n`-terminated, quoted
multi-word values with backslash escapes. Nutty bundles SwiftNIO for this, which is a lot
of framework for a line protocol.

Needed: `VER`, `NETVER`, `LIST UPS`, `LIST VAR <ups>`, `LIST CMD <ups>`,
`GET VAR <ups> <var>`, `USERNAME`/`PASSWORD`, `LOGIN`, `INSTCMD`, `LOGOUT`, `STARTTLS`.
`LIST` replies are framed `BEGIN LIST <query>` … `END LIST <query>`. Errors are
`ERR <TOKEN>`; handle `ACCESS-DENIED`, `UNKNOWN-UPS`, `DRIVER-NOT-CONNECTED`,
`DATA-STALE`, `USERNAME-REQUIRED`, `PASSWORD-REQUIRED`, `INVALID-USERNAME`,
`INVALID-PASSWORD` by name.

Two that matter beyond polling:

- **`DATA-STALE` / `DRIVER-NOT-CONNECTED` must set `Is Present = false`** (or stop
  publishing). Never hand `powerd` a cheerful stale reading — that is how you fail to
  shut down.
- **`FSD`** (forced shutdown) in `ups.status` is the NUT server ordering shutdown. Map it
  to an immediate critical publish, never to a threshold.

Support `STARTTLS`, which Nutty's page doesn't mention. Credentials in Keychain.

---

## 10. App Intents surface

In place from v1, not bolted on. One design decision up front: **every read intent
returns a value, not just a dialog.** Otter's intents return dialog strings, which is
right for Siri but useless in a Shortcuts automation. Squirrel's users will absolutely
build "if the UPS goes on battery, shut down the NAS and text me" — so intents must chain.

### Entity

Model the UPS as one entity with `@Property` fields rather than a separate intent per
reading. Shortcuts can then pull any field off the result of a single `Get UPS` step.

```swift
enum UPSStatusAppEnum: String, AppEnum {
    case online, onBattery, lowBattery, charging, replaceBattery, forcedShutdown, offline, unknown
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "UPS Status")
    static let caseDisplayRepresentations: [UPSStatusAppEnum: DisplayRepresentation] = [
        .online: "On line power", .onBattery: "On battery", .lowBattery: "Low battery",
        .charging: "Charging", .replaceBattery: "Replace battery",
        .forcedShutdown: "Forced shutdown", .offline: "Offline", .unknown: "Unknown",
    ]
}

struct UPSEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "UPS")
    static let defaultQuery = UPSQuery()

    let id: UUID
    @Property(title: "Name")                var name: String
    @Property(title: "Status")               var status: UPSStatusAppEnum
    @Property(title: "Battery Level")        var batteryLevel: Int?
    @Property(title: "Estimated Runtime")    var runtime: Measurement<UnitDuration>?
    @Property(title: "Load")                 var load: Int?
    @Property(title: "On Battery")           var isOnBattery: Bool
    @Property(title: "Visible to macOS")     var isPublishedToSystem: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(status.rawValue) · \(batteryLevel.map { "\($0)%" } ?? "—")"
        )
    }
}
```

Use `EntityPropertyQuery` (not just `EntityStringQuery`) so automations can filter —
"find UPS where Battery Level is under 50".

### Intents

| Intent | Returns | Notes |
|---|---|---|
| `GetUPSIntent` | `ReturnsValue<UPSEntity>` & `ProvidesDialog` | the workhorse; everything else is a property read |
| `GetUPSBatteryLevelIntent` | `ReturnsValue<Int>` | convenience for one-step automations |
| `GetUPSRuntimeIntent` | `ReturnsValue<Measurement<UnitDuration>>` | |
| `GetSystemPowerSourceIntent` | `ReturnsValue<UPSStatusAppEnum>` | reads `IOPSCopyPowerSourcesInfo` — answers *"what does macOS think?"*, the one intent that proves our integration works |
| `RefreshUPSIntent` | `ProvidesDialog` | force a poll now |
| `RunUPSSelfTestIntent` | `ProvidesDialog` | `INSTCMD test.battery.start.quick`, gated on `LIST CMD` |
| `SetUPSBeeperIntent` | `ProvidesDialog` | `AppEnum` param → `beeper.mute` / `.enable` / `.disable` |
| `PauseSquirrelIntent` / `ResumeSquirrelIntent` | `ProvidesDialog` | pause monitoring **and** unpublish, since a paused monitor must not keep asserting a healthy UPS |
| `OpenUPSEnergySettingsIntent` | — | deep-links System Settings → Battery; pairs with §4's trap |

All `static let openAppWhenRun = false`. Follow Otter's `OtterIntentBridge` pattern: a
`@MainActor enum SquirrelIntentBridge` holding a `weak var appModel`, with a
`resolve(upsID:)` helper and two typed errors (`appUnavailable`, `upsNotFound`). When the
daemon lands in v1.1, point the bridge at the daemon over XPC so intents work with no GUI
running.

`AppShortcutsProvider` for the Siri phrases (cap is 10; phrases must interpolate
`\(.applicationName)`):

```swift
AppShortcut(intent: GetUPSIntent(),  phrases: ["What's my \(.applicationName) status",
                                              "Check \(.applicationName)"],
            shortTitle: "Check UPS",  systemImageName: "bolt.fill")
AppShortcut(intent: PauseSquirrelIntent(),  phrases: ["Pause \(.applicationName)"],  …)
AppShortcut(intent: ResumeSquirrelIntent(), phrases: ["Resume \(.applicationName)"], …)
```

`squirrelctl` should mirror this surface one-for-one (`status`, `refresh`, `self-test`,
`pause`, `resume`, `export-diagnostics`) over distributed notifications, as `otterctl`
does — no network port.

---

## 11. Onboarding — the other named bug

The reported onboarding bugs have a specific cause visible across the UniFi/Unraid/Proxmox
threads: **the NUT UPS name must match the ID set in the UniFi controller**, people guess
it, and every tool then shows nothing with no useful error. Nutty makes the user type it.

We never ask. Connect → `LIST UPS` → enumerate the real names → show them with live
`battery.charge` / `ups.status` beside each → user picks → save. One screen, no guessing,
and the live reading proves it worked before anything is persisted.

Otter already has the pieces to copy: a first-run assistant, a Connection Readiness test,
discovery, and the Local Network permission handled gracefully. Squirrel needs that
permission too (`NSLocalNetworkUsageDescription`, §7) and should explain itself before
macOS asks.

Discovery: NUT doesn't advertise over Bonjour, so probe 3493 across the local subnet and
the default gateway (a UniFi gateway is the overwhelmingly likely host). Otter's
`NetworkReachabilityService` / `SMBDiscoveryService` are the template.

Built as `SquirrelCore/NUT/NUTDiscovery.swift`: the candidate addresses come from
`getifaddrs`, clamped to the /24 this Mac sits in so a wide netmask cannot turn discovery
into a sweep of tens of thousands of hosts, and a host is only reported once it has
answered `LIST UPS` in NUT's own protocol. The probe speaks NUT over the *same* socket it
used to test the port — opening one connection to check and a second to talk is two
connections in quick succession, which a UPS server serving one client at a time simply
refuses, and that showed up as discovery intermittently finding nothing.

---

## 12. Killing the UI jank

Otter already encodes the fix: `.menuBarExtraStyle(.menu)`. A native `NSMenu` cannot have
animation bugs, because we are not animating anything — the system draws it. Custom
SwiftUI popover panels hosted off a status item are where the little animation glitches
live, and that is almost certainly what Nutty does.

So: native menu for status and actions, a real `Window` for management, the `Settings`
scene for preferences — exactly Otter's three-scene structure, carrying over its
`applicationShouldTerminateAfterLastWindowClosed → false` and
`disableAutomaticTermination` notes (doubly important here, per §7).

**One SwiftUI trap in the management window.** `DisclosureGroup(_:isExpanded:)` inside a
`Section` of a `.formStyle(.grouped)` form never writes back to its binding on macOS 27:
the row draws and reads its state correctly, but neither a click, a keypress nor an
accessibility `AXPress` toggles it, so the section is stuck at whatever it started as and
is unreachable from the keyboard or VoiceOver. `DisclosureRow` in
`Squirrel/Views/DisclosureRow.swift` draws the same row from a real `Button`, which every
input method can actuate. Verified against the Technical Information section and the
assistant's Authentication fields — the latter was a functional bug, since credentials
could not be entered at all.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Undocumented API changes in a future macOS | Graceful degradation: if `IOPSCreatePowerSource` fails, fall back to in-app rules + a loud notification that native integration is off. Never silently stop protecting the Mac. CI check that the symbol still resolves. |
| Halt settings ignored (§5) | Settle with the drill before building. |
| App crash or macOS reaping the process = no UPS | Daemon (§8); meanwhile the two termination keys, `disableAutomaticTermination`, and a watchdog. |
| Flapping NUT data flips the power profile | Debounce the OL→OB transition (the glitch-filter project defaults to 20s), but **never** debounce `FSD` or `LB`. |
| A real USB UPS also attached | Detect an existing UPS source and don't publish a duplicate; offer to stay display-only. |
| Lying to `powerd` | Freshness is a first-class input: stale ⇒ not present. |
| Icon fallback on 13.0 (§6) | Verify on a Ventura VM before advertising the floor. |
| System Settings caches a withdrawn UPS | Observed: after the power source is released, System Settings → Energy keeps showing the stale `UPS Level: …` header (the UPS Options button does disappear) until the app is relaunched. `pmset -g ps` is the honest check. Users who pause Squirrel will read this as a bug, so say so in the pause confirmation rather than letting them find it. |

---

## 14. Build order

1. **The drill in §5.** Everything downstream depends on the answer. Do not skip to code.
2. `NUTClient` + tests against the real UniFi server (no UI).
3. `PowerSourcePublisher`, hardened: freshness, debounce, FSD, degradation.
4. Menu bar + native menu, Otter's three scenes, `Squirrel.icon` wired up.
5. Onboarding with `LIST UPS` enumeration.
6. `PowerProfileAdvisor` + sleep assertion (the §4 trap).
7. App Intents (§10) + `squirrelctl`.
8. Notifications, event log, Sparkle + ShipHook, website.
9. v1.1: lift 2–3 into a LaunchDaemon for login-window parity.

---

## Appendix — verification commands

```bash
# the three symbols are linkable in the SDK
grep -o "_IOPS[A-Za-z]*PowerSource[A-Za-z]*" \
  "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit.tbd" | sort -u

# Apple's own UPS daemon uses exactly these
nm -u /usr/libexec/ioupsd | grep IOPS

# Nutty does not
nm -u /Applications/Nutty.app/Contents/MacOS/NUTty | grep -iE "IOPS|IOPM"   # (none)

# publish a UPS from an ordinary user process, and watch the system see it
swiftc -O research/SwiftProbe.swift -o swiftprobe
codesign --force --sign - --options runtime swiftprobe     # hardened runtime: still works
./swiftprobe & sleep 2; pmset -g ps

# native UPS thresholds, and the UPS Power profile's sleep timers
pmset -g ups
pmset -g custom
```
