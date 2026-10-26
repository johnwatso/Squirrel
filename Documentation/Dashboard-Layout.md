# Dashboard reference layout

The reference the main window was first built from. The window has since moved to a sidebar of UPSes, system text styles and system colours (see the 27 October entry in [UI-Verification.md](UI-Verification.md)); the geometry below is the original target, not a specification.

Source: `/Users/john/Desktop/image.png`, 1536 × 1024 pixels. Only the left dashboard is in scope. Coordinates below are measured from its top-left corner and treated as macOS points for comparison.

- Window: approximately 682 × 903; portrait proportion 0.755. Native traffic lights and title occupy the left of a 58-point toolbar. UPS selector sits near x318, then schedule, history, and overflow controls on the right. Selector popover is about 262 × 230, with a heading, two-line device entries, status dots/checkmark, and separated Manage/Add actions.
- Content: 22-point horizontal margins, 638-point cards. Off-white background, very subtle neutral borders, 12-point corner radii; no prominent shadows inside the dashboard.
- Overview: y58–389 (330 high). Identity at x35/y80: 115 × 88 muted image well; name at x171/y88, 20-point semibold; manufacturer/capacity and status below, 14-point regular, about 28 points between baselines. Header divider at y180.
- Measurements: x50/y204. Battery and runtime begin at x50 and x247. Labels 14-point secondary, values 24-point semibold. Battery bar 169 × 10 at y262; runtime annotation shares its vertical level. Horizontal divider at y296, inset 28 points. Lower row: power consumption at x50/y320; UPS load label x306; 64-point ring at x402/y311, then short vertical divider at x487. Leave the right portion open as in the reference.
- macOS Connection (originally "Mac Protection"): y398–577, 179 high; shield and 16-point semibold heading inset 20, status aligned right. Inset rounded table starts y451, with three 36-point rows. Labels left, secondary values right; separators inset 18.
- Power Management: y577–800, 223 high. Clock and heading match protection; table has three 36-point rows; Edit Schedule button right aligned beneath, about 134 × 32. Keep existing schedule actions and dynamic summaries; do not change scheduling implementation.
- Technical Information: y816–870, 54 high, collapsed; chevron and label left, freshness text and green dot right. 16-point gap above, about 33 below. Expansion must remain scrollable.
- Colour: primary near-black text; secondary cool grey; green for healthy power/battery/load/freshness; native blue action tint. Preserve semantic warning/error colours and dark appearance support.

Implementation uses a scroll view, explicit card insets and native SwiftUI text/buttons/popover. Widths adapt below the reference size. Real telemetry, missing/stale states, protection explanations and all existing actions remain available. The reference's other windows are excluded.
