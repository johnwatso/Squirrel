import Foundation
import SquirrelCore

/// How serious what the UPS is reporting actually is.
///
/// Separate from whether Squirrel can reach the server, and from whether macOS
/// has accepted the power source: a UPS can be perfectly healthy while either
/// of those is broken, and vice versa.
enum UPSSeverity: Equatable {
    case normal
    case caution
    case critical
}

/// Turns `ups.status` into something a person can read.
///
/// `ups.status` is a list, not a single value — `"OL CHRG"` and `"OB LB"` are
/// both ordinary — so this gives one headline and keeps the rest as separate
/// conditions rather than throwing them away.
enum UPSStatusPresentation {
    /// The one thing most worth saying about the UPS right now.
    static func headline(for status: UPSStatusFlags) -> String {
        if status.contains(.forcedShutdown) { return "Forced shutdown initiated" }
        if status.contains(.lowBattery) { return "Low battery" }
        if status.contains(.onBattery) { return "Running on battery" }
        if status.contains(.bypass) { return "Bypass active" }
        if status.contains(.calibrating) { return "Calibrating" }
        if status.contains(.offline) { return "Output off" }
        if status.contains(.online) { return "On mains power" }
        return "Status unknown"
    }

    /// Everything else the UPS is reporting at the same time, without
    /// repeating the headline.
    static func conditions(for status: UPSStatusFlags) -> [String] {
        let headline = headline(for: status)
        let all: [(UPSStatusFlags, String)] = [
            (.online, "On mains power"),
            (.onBattery, "Running on battery"),
            (.lowBattery, "Low battery"),
            (.highBattery, "Battery full"),
            (.replaceBattery, "Replace battery"),
            (.charging, "Charging"),
            (.discharging, "Discharging"),
            (.overload, "Overloaded"),
            (.bypass, "Bypass active"),
            (.calibrating, "Calibrating"),
            (.boosting, "Boosting voltage"),
            (.trimming, "Trimming voltage"),
            (.offline, "Output off"),
            (.alarm, "Alarm"),
            (.forcedShutdown, "Forced shutdown initiated"),
        ]
        return all.compactMap { flag, text in
            status.contains(flag) && text != headline ? text : nil
        }
    }

    static func severity(for status: UPSStatusFlags) -> UPSSeverity {
        if status.contains(.forcedShutdown) || status.contains(.lowBattery)
            || status.contains(.alarm) || status.contains(.overload) {
            return .critical
        }
        if status.contains(.onBattery) || status.contains(.replaceBattery)
            || status.contains(.bypass) || status.contains(.calibrating)
            || status.contains(.offline) {
            return .caution
        }
        return .normal
    }

    /// The whole status in one line, for the menu bar and lists.
    ///
    /// Runtime is shown whenever the UPS reports it — during an outage it is
    /// how long you have, and the rest of the time it is how long you would
    /// have — so the wording changes but the number is always there.
    static func summary(for reading: UPSReading) -> String {
        var parts = [headline(for: reading.status)]
        if let charge = reading.batteryCharge { parts.append("\(charge)%") }
        if let runtime = reading.batteryRuntime {
            let formatted = UPSTelemetry.duration(seconds: runtime)
            parts.append(reading.status.isRunningOnBattery ? "\(formatted) left" : "\(formatted) runtime")
        }
        return parts.joined(separator: " · ")
    }
}

/// One label/value pair built from a variable this UPS actually reported.
struct UPSTelemetryField: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

/// Reads the variables a UPS reports and formats the ones worth showing.
///
/// Every field is driven by what came back from `LIST VAR`: a UPS that does
/// not report a value simply has no row, rather than a row reading zero.
enum UPSTelemetry {
    /// How a raw NUT value should be written out.
    private enum Unit {
        case text
        case percent
        case volts
        case hertz
        case celsius
        case watts
        case voltAmps
        case seconds

        func format(_ raw: String) -> String? {
            switch self {
            case .text:
                return raw
            case .percent:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number))%"
            case .volts:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number)) V"
            case .hertz:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number)) Hz"
            case .celsius:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number)) °C"
            case .watts:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number)) W"
            case .voltAmps:
                guard let number = Double(raw) else { return raw }
                return "\(Self.trim(number)) VA"
            case .seconds:
                guard let number = Double(raw) else { return raw }
                return duration(seconds: Int(number))
            }
        }

        /// Drops a pointless ".0" without rounding away a real decimal.
        private static func trim(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
    }

    /// A row the UI may show: the first variable that this UPS reports wins,
    /// so `device.model` is preferred over `ups.model` without needing both.
    private struct Spec {
        let label: String
        let keys: [String]
        let unit: Unit

        init(_ label: String, _ keys: [String], _ unit: Unit = .text) {
            self.label = label
            self.keys = keys
            self.unit = unit
        }
    }

    private static let device: [Spec] = [
        Spec("Manufacturer", ["device.mfr", "ups.mfr"]),
        Spec("Model", ["device.model", "ups.model"]),
        Spec("Serial number", ["device.serial", "ups.serial"]),
        Spec("Firmware", ["ups.firmware"]),
        Spec("Temperature", ["ups.temperature"], .celsius),
    ]

    private static let battery: [Spec] = [
        Spec("Charge", ["battery.charge"], .percent),
        Spec("Runtime", ["battery.runtime"], .seconds),
        Spec("Voltage", ["battery.voltage"], .volts),
        Spec("Temperature", ["battery.temperature"], .celsius),
        Spec("Low-charge threshold", ["battery.charge.low"], .percent),
        Spec("Low-runtime threshold", ["battery.runtime.low"], .seconds),
        Spec("Type", ["battery.type"]),
    ]

    private static let electrical: [Spec] = [
        Spec("Load", ["ups.load"], .percent),
        Spec("Real power", ["ups.realpower"], .watts),
        Spec("Apparent power", ["ups.power"], .voltAmps),
        Spec("Input voltage", ["input.voltage"], .volts),
        Spec("Output voltage", ["output.voltage"], .volts),
        Spec("Input frequency", ["input.frequency"], .hertz),
        Spec("Output frequency", ["output.frequency"], .hertz),
        Spec("Nominal power", ["ups.realpower.nominal"], .watts),
        Spec("Nominal apparent power", ["ups.power.nominal"], .voltAmps),
    ]

    private static let driver: [Spec] = [
        Spec("Driver", ["driver.name"]),
        Spec("Driver version", ["driver.version"]),
    ]

    static func deviceFields(for reading: UPSReading) -> [UPSTelemetryField] {
        fields(device, from: reading)
    }

    static func batteryFields(for reading: UPSReading) -> [UPSTelemetryField] {
        fields(battery, from: reading)
    }

    static func electricalFields(for reading: UPSReading) -> [UPSTelemetryField] {
        fields(electrical, from: reading)
    }

    static func driverFields(for reading: UPSReading) -> [UPSTelemetryField] {
        fields(driver, from: reading)
    }

    private static func fields(_ specs: [Spec], from reading: UPSReading) -> [UPSTelemetryField] {
        specs.compactMap { spec in
            for key in spec.keys {
                guard let raw = reading.value(key), let formatted = spec.unit.format(raw) else { continue }
                return UPSTelemetryField(id: key, label: spec.label, value: formatted)
            }
            return nil
        }
    }

    /// "Ubiquiti · 1500 VA": who made it and how big it is, which is how
    /// people tell UPSes apart. Never the NUT identifier, which belongs in
    /// Technical Information; the model is only a fallback for the size.
    static func identity(for reading: UPSReading?) -> String? {
        guard let reading else { return nil }
        var parts: [String] = []
        if let maker = UPSNaming.manufacturer(in: reading) {
            parts.append(maker)
        }
        if let va = reading.number("ups.power.nominal") {
            parts.append("\(Int(va)) VA")
        } else if let watts = reading.number("ups.realpower.nominal") {
            parts.append("\(Int(watts)) W")
        } else if let model = reading.model {
            parts.append(model)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whole watts for an at-a-glance value; the technical list keeps decimals.
    static func watts(_ reading: UPSReading) -> String? {
        reading.number("ups.realpower").map { "\(Int($0.rounded())) W" }
    }

    static func voltAmps(_ reading: UPSReading) -> String? {
        reading.number("ups.power").map { "\(Int($0.rounded())) VA" }
    }

    /// Seconds as a person would say them: "42 min", "1 hr 1 min".
    static func duration(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}
