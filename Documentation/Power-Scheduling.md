# Native power scheduling — 23 October 2026

Squirrel edits the Mac's system schedule. It does not run a second scheduler.
The dashboard selection is independent of the single UPS designated for Mac
protection. Selecting another dashboard never republishes a power source.

## Interfaces investigated

The installed macOS 27 SDK publicly declares `IOPMSchedulePowerEvent`,
`IOPMCancelScheduledPowerEvent` and `IOPMCopyScheduledPowerEvents` in
`IOKit/pwr_mgt/IOPMLib.h`. Creation and cancellation require root; reading does
not. One-time events are persistent system events and have a date, type and
owner. Squirrel reads these through `IOPMCopyScheduledPowerEvents` and displays
them read-only, preserving the original owner's events.

The requested `IOPMSetRepeatingPowerEvents` is not declared in that public SDK.
Apple's pmset source instead calls `IOPMScheduleRepeatingPowerEvent` and
`IOPMCopyRepeatingPowerEvents`, using private IOKit headers. Squirrel does not
resolve or call these symbols. It uses the supported `/usr/bin/pmset repeat`
command for recurring schedules and `/usr/bin/pmset -g sched` for readback.
No new private framework or undocumented function is used for scheduling.
The existing UPS publisher retains its original undocumented IOKit integration.

macOS supports **one recurring startup/wake rule and one recurring sleep,
restart or shutdown rule**. Each rule has a weekday mask and a local wall-clock
time. Three independently recurring rules as depicted in the reference cannot
be represented by this system facility. The card list exposes the two real slots, with a dedicated Add/Edit sheet,
native time picker, recurrence presets, custom weekdays and per-rule enable/disable.
The editor disables actions belonging to an occupied slot. Wake, startup and
combined startup/wake remain explicit choices within the same slot. Disabled rules
are saved as editor drafts only; they do not execute and do not supersede an
active system rule. There is no custom scheduling engine or rolling queue.

### Readback caveat

For arbitrary weekday combinations, pmset prints “Some days”, omitting the mask.
Squirrel then reads the `RepeatingPowerOn`/`RepeatingPowerOff` dictionary from
`/Library/Preferences/SystemConfiguration/com.apple.AutoWake.plist`, requiring its
time and type to agree with pmset before accepting its weekday mask. **This
backing-file format is an implementation detail, not a supported scheduling
API.** The file is never edited. If unreadable or changed, editing is disabled
with an explanation, rather than guessing days or deleting an unknown rule.
Common masks (daily, weekdays, weekends, individual days) need no fallback.

## Permission and preservation

There is no existing privileged helper to reuse. Saving, toggling or deleting an
active rule submits one
validated pmset command through Standard Additions' `do shell script ... with
administrator privileges`, run in Squirrel's own process with `NSAppleScript`.
The system owns the authentication prompt; Squirrel never handles a password.

The prompt names the process that requests authorisation. When this ran through
a child `/usr/bin/osascript`, macOS 27 titled it “Allow administrator access for
a script started by ‘Squirrel’?”. In-process it reads “Allow administrator access
for ‘Squirrel’?” and “Enter your password to continue with ‘Squirrel’”. Checked
side by side on macOS 27.0.1 with a hardened-runtime, ad-hoc-signed test bundle;
no entitlement is needed because no Apple event leaves the process.

The rest of the prompt depends on whether Gatekeeper accepts the requesting app:

- **Unverified (ad-hoc or development builds, `spctl --assess` rejects them).**
  No icon, no lock badge, and an extra paragraph: “Apple could not verify this
  app is free of malware…”. `AuthorizationCopyRights` (Authorization Services)
  produced the same dialog, so a different API or a helper does not change this.
- **Verified.** An Apple-signed requester (`security authorize -u
  system.privilege.admin`) got the lock badged with its icon and no malware
  paragraph. A Developer ID-signed, notarised Squirrel should get the same with
  its own icon. That has to be confirmed on a ShipHook build; no Developer ID
  identity is available on the development Mac.
- **No custom text either way.** The `with prompt` string is not shown on
  macOS 27. It is kept because earlier macOS versions display it.

`NSAppleScript` is main-thread only, so the menu bar UI does not redraw while the
system prompt is up. The prompt is modal anyway and pmset returns quickly. Authentication cancellation
is shown as a concise message and leaves the editor open for retry. Local-only
disabled-rule creation, editing and deletion do not request authorization. A permanently installed
root daemon is unnecessary for these occasional changes. Subsequent operations
use macOS's authorization behaviour; an indefinite authentication cache is not
promised. Restart-after-failure changes use the same path.

The command contains only enum action names, validated weekday tokens and
validated numeric times. Arguments and the readback baseline are shell-quoted,
and the shell command is separately escaped as an AppleScript string.

Existing repeating slots are loaded together. A change intentionally replaces
the shared recurring configuration, as explained in the sheet, while preserving
the other loaded slot. One-time events are never cancelled or rewritten. The
original snapshot is checked before authentication and again inside the
privileged operation. If another app changes the schedule, Squirrel rejects the
edit. There is no cross-process compare-and-swap API: another writer can still
race the final check/pmset invocation. Readback must agree with the requested
active pair before success is reported or disabled drafts are committed. The
verified snapshot updates the UI directly, avoiding a second fallible read after
commit. The authorization-time snapshot uses the same C locale as the reader.

### Why not a new privileged helper?

The installed `SMAppService.h` documents that a LaunchDaemon must be approved by
an administrator in System Settings before it is bootstrapped, and its containing
app must be notarized. SMAppService manages registration; it does not make an
ordinary app privileged or eliminate consent. A future helper would need a signed,
notarized daemon, a narrow XPC interface with client validation, lifecycle handling,
and explicit installation/approval UI. That architectural change is not warranted
solely to alter the wording of an occasional authentication prompt. The supported
existing backend is retained; authentication caching remains controlled by macOS.

## Platform and recovery limits

On the development Apple silicon Mac running macOS 27.0.1, read-only pmset
queries succeeded, no scheduled events were present, and `pmset -g cap` reported
`autorestart`. The existing AC profile had that option enabled. The Power settings
toggle is disabled when capability or the current value cannot be established.

The APIs and pmset document wake, poweron/wake-or-poweron, sleep, restart and
shutdown requests. They do **not** establish that every hardware model can
execute every request from every system state. There is no reliable per-action
scheduled-startup capability query in the public interfaces inspected. Squirrel
therefore describes startup as hardware-dependent and offers Wake separately;
it does not label scheduled startup as verified on this Apple silicon Mac.
Intel and Apple silicon firmware behaviour still require physical testing.

Apple documents that scheduled shutdown requires the Mac to be awake and a user
to be logged in; unsaved documents may prevent shutdown or sleep. FileVault
requires a login after startup. A closed laptop lid, unavailable power and other
firmware conditions can affect wake/startup. Acceptance and persistence of a
schedule are different from successful execution.

Restart after power failure is separate from scheduling. A normal shutdown while
a UPS continues supplying AC does not itself create a power-restoration edge.
Shutdown followed by actual AC loss and restoration may permit automatic startup,
depending on the Mac and firmware. Neither native UPS recognition nor autorestart
alone guarantees unattended recovery.

## History semantics

Existing SQLite storage, retention, sampling, aggregation and missing-data gaps
are retained. The power chart adds event markers; Recent Events includes event
provenance. UPS changes are observations made by Squirrel. NSWorkspace wake,
will-sleep and will-power-off notifications are recorded as reported by macOS,
with the cause and completion unverified. A saved schedule is recorded as a
configuration change, not a successful shutdown or startup. No event is inferred
from the app ceasing to record readings. Notifications seen while Squirrel is
closed are not backfilled or fabricated; scheduled startup execution is not
claimed without evidence. A will-power-off notification may not be flushed before
termination and must not be used as an audit guarantee.

## References

- [Apple: Schedule your Mac to turn on or off in Terminal](https://support.apple.com/guide/mac-help/mchl40376151/mac)
- [Apple: IOPMSchedulePowerEvent](https://developer.apple.com/documentation/iokit/1557076-iopmschedulepowerevent)
- [Apple: IOPMCopyScheduledPowerEvents](https://developer.apple.com/documentation/iokit/1557109-iopmcopyscheduledpowerevents)
- [Apple: public IOPMLib interfaces](https://developer.apple.com/documentation/iokit/iopmlib_h)
- [Apple's pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: do shell script in AppleScript](https://developer.apple.com/library/archive/technotes/tn2065/_index.html)
- Installed Standard Additions scripting dictionary: `do shell script` / `with prompt`.
- Local `man pmset`: Scheduled Event Arguments, UPS Specific Arguments, and
  `autorestart`. All scheduling code retains Squirrel's macOS 13 deployment target.

## Verification boundaries

No power schedule was applied to the development Mac, no administrator credential
was requested, and no sleep, restart, shutdown, outage or UPS power cycle was
triggered. Automated tests use injected readers/writers for mutations and cover
readback, disabled-draft persistence across service recreation, preserving the
other recurring slot, stale edits, weekday masks and invalid combinations.
Administrator authorization, persistence across a real reboot, scheduled wake,
startup from off, and actual UPS shutdown/recovery remain physical acceptance
tests. Test those on a disposable test Mac, including FileVault, lid state and
both Intel and Apple silicon as applicable.
