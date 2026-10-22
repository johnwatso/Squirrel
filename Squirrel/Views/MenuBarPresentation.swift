import Foundation
import SquirrelCore

/// Turns a reading into the short strings and symbol names the menu bar uses,
/// kept out of the views so it can be reasoned about (and tested) on its own.
enum MenuBarPresentation {
    /// One-line summary: "Running on battery · 87% · 28 min left".
    static func summary(for state: UPSConnectionState) -> String {
        switch state {
        case .online(let reading):
            return UPSStatusPresentation.summary(for: reading)
        case .failed(let message):
            return message
        case .connecting:
            return "Connecting…"
        case .idle:
            return "Not monitoring"
        }
    }

    /// "120 W · 12% load": what the UPS is supplying, where it reports it.
    static func drawLine(for state: UPSConnectionState) -> String? {
        guard let reading = state.reading else { return nil }
        var parts: [String] = []
        if let watts = UPSTelemetry.watts(reading) { parts.append(watts) }
        if let load = reading.load { parts.append("\(load)% load") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Explicit, short measurements for the native menu. Unsupported values
    /// are omitted and disconnected devices never inherit another UPS's data.
    static func measurementLines(for state: UPSConnectionState) -> [String] {
        guard let reading = state.reading else { return [] }
        var lines: [String] = []
        if let charge = reading.batteryCharge { lines.append("Battery: \(charge)%") }
        if let runtime = reading.batteryRuntime {
            lines.append("Runtime: \(UPSTelemetry.duration(seconds: runtime))")
        }
        if let power = UPSTelemetry.watts(reading) { lines.append("Power: \(power)") }
        else if let power = UPSTelemetry.voltAmps(reading) { lines.append("Apparent power: \(power)") }
        if let load = reading.load { lines.append("Load: \(load)%") }
        return lines
    }

    static func statusPhrase(for status: UPSStatusFlags) -> String {
        UPSStatusPresentation.headline(for: status)
    }

    /// Everything `ups.status` is reporting, headline first, for the detail
    /// submenu. A UPS commonly reports several flags at once.
    static func flagDescriptions(for status: UPSStatusFlags) -> [String] {
        [UPSStatusPresentation.headline(for: status)] + UPSStatusPresentation.conditions(for: status)
    }

    /// Only long-standing SF Symbols, so the icon renders on Ventura too.
    static func symbolName(for state: UPSConnectionState) -> String {
        switch state {
        case .online(let reading):
            if reading.status.isCritical { return "exclamationmark.triangle.fill" }
            guard reading.status.isRunningOnBattery else { return "bolt.fill" }
            return batterySymbol(forCharge: reading.batteryCharge)
        case .failed:
            return "bolt.slash.fill"
        case .connecting, .idle:
            return "bolt.slash"
        }
    }

    static func batterySymbol(forCharge charge: Int?) -> String {
        guard let charge else { return "battery.50" }
        switch charge {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    /// The text beside the icon, if any.
    static func menuBarText(for state: UPSConnectionState, display: MenuBarDisplay) -> String? {
        guard case .online(let reading) = state, let charge = reading.batteryCharge else { return nil }
        switch display {
        case .iconOnly:
            return nil
        case .alwaysPercentage:
            return "\(charge)%"
        case .percentageDuringOutage:
            return reading.status.isRunningOnBattery ? "\(charge)%" : nil
        }
    }

    /// NUT instant commands worth putting in a menu, with readable titles.
    static let offeredCommands: [(command: String, title: String)] = [
        ("test.battery.start.quick", "Run Quick Self-Test"),
        ("test.battery.start.deep", "Run Deep Self-Test"),
        ("test.battery.stop", "Stop Self-Test"),
        ("beeper.mute", "Mute Beeper"),
        ("beeper.disable", "Disable Beeper"),
        ("beeper.enable", "Enable Beeper"),
    ]
}
