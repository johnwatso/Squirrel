# Showing the Mac's own power draw — parked

Status: investigated 27 October 2026 and **not built**. The reading macOS
exposes isn't reliable enough to show beside the UPS's watts. Revisit if one of
the sources under "What would work" becomes available.

## The idea

Show how much of the UPS's load is this Mac, for example "This Mac: 9 W" next to
the UPS's "140 W", so people can see what the rest of their equipment draws.

## What macOS offers

Apple documents no API for a Mac's total power draw. Two unofficial sources
exist:

- **`powermetrics`** needs administrator rights and reports the chip's own
  power (CPU, GPU, Neural Engine), not the whole Mac at the wall.
- **IOKit's `AppleSmartBattery` entry** is published even on a Mac mini with no
  battery. Any app can read it without privileges. Its `PowerTelemetryData`
  dictionary holds `SystemPowerIn` and `SystemLoad` (milliwatts, by the look of
  the values) and an accumulator, `AccumulatedWallEnergyEstimate`, with a sample
  count, `SystemPowerInAccumulatorCount`.

```sh
ioreg -rn AppleSmartBattery | grep -oE '"(SystemPowerIn|SystemLoad)"=[0-9]+'
```

## What was measured

On the Mac mini (M1, macOS 27.0.1) behind the UniFi UPS 2U, about 4½ minutes
were logged, idle and then with every core busy (`yes > /dev/null` per core),
alongside the UPS's `ups.realpower`:

| Phase | `SystemPowerIn` | UPS total (per-minute average) |
|---|---|---|
| Idle | 2.2 W | 135–137 W |
| Full load | 10.5 W | 135–141 W |

## Why it isn't shown

- **It updates about once a minute.** Each update covers about 58 one-second
  samples and holds still in between. A 24-second burst of full load never
  appeared in it.
- **It probably isn't wall power.** 2.2 W idle is well below the roughly 7 W
  Apple quotes for an idle M1 Mac mini at the wall. It looks like the power the
  Mac uses internally, after its power supply. Beside the UPS's figure it would
  understate the Mac's share several times over.
- **The UPS can't check it.** `ups.realpower` moves in 10 W steps, and its noise
  was as large as the Mac's rise of about 8 W under load.
- **It's undocumented and model-specific.** On a laptop the same keys most
  likely describe the charger's input, and each kind of Mac would need checking.
- **The accumulator doesn't help.** It also changes once a minute (by about
  1,000–1,100 per sample at idle and 3,400 under sustained load), and its units
  don't map onto a watt figure that matches `SystemPowerIn` or the UPS.

## What would work

- **Per-outlet power from the UPS.** Some UPSes report `outlet.<n>.realpower`
  over NUT, which would give the Mac's share exactly. The UniFi UPS 2U doesn't
  list it.
- **A metering smart plug** between the Mac and the UPS.
- **A documented macOS API**, if Apple ever publishes one.

If revisiting `SystemPowerIn`, test it on a laptop and an Intel Mac, and compare
it with a wall meter rather than the UPS.
