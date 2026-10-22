import Foundation

/// The flags carried in `ups.status`, which is a space-separated list such as
/// `"OL CHRG"` or `"OB LB"`.
public struct UPSStatusFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let online            = UPSStatusFlags(rawValue: 1 << 0)  // OL
    public static let onBattery         = UPSStatusFlags(rawValue: 1 << 1)  // OB
    public static let lowBattery        = UPSStatusFlags(rawValue: 1 << 2)  // LB
    public static let highBattery       = UPSStatusFlags(rawValue: 1 << 3)  // HB
    public static let replaceBattery    = UPSStatusFlags(rawValue: 1 << 4)  // RB
    public static let charging          = UPSStatusFlags(rawValue: 1 << 5)  // CHRG
    public static let discharging       = UPSStatusFlags(rawValue: 1 << 6)  // DISCHRG
    public static let bypass            = UPSStatusFlags(rawValue: 1 << 7)  // BYPASS
    public static let calibrating       = UPSStatusFlags(rawValue: 1 << 8)  // CAL
    public static let offline           = UPSStatusFlags(rawValue: 1 << 9)  // OFF
    public static let overload          = UPSStatusFlags(rawValue: 1 << 10) // OVER
    public static let trimming          = UPSStatusFlags(rawValue: 1 << 11) // TRIM
    public static let boosting          = UPSStatusFlags(rawValue: 1 << 12) // BOOST
    public static let forcedShutdown    = UPSStatusFlags(rawValue: 1 << 13) // FSD
    public static let alarm             = UPSStatusFlags(rawValue: 1 << 14) // ALARM

    private static let tokens: [String: UPSStatusFlags] = [
        "OL": .online, "OB": .onBattery, "LB": .lowBattery, "HB": .highBattery,
        "RB": .replaceBattery, "CHRG": .charging, "DISCHRG": .discharging,
        "BYPASS": .bypass, "CAL": .calibrating, "OFF": .offline, "OVER": .overload,
        "TRIM": .trimming, "BOOST": .boosting, "FSD": .forcedShutdown, "ALARM": .alarm,
    ]

    /// Parses a raw `ups.status` value. Unrecognised tokens are ignored rather
    /// than failing: vendors add their own, and an unknown flag is not a reason
    /// to stop protecting the Mac.
    public init(statusString: String) {
        var flags = UPSStatusFlags()
        for token in statusString.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let flag = Self.tokens[String(token).uppercased()] { flags.insert(flag) }
        }
        self = flags
    }

    /// True when the UPS is running from its battery. `FSD` counts: the server
    /// has ordered a shutdown and the Mac should treat that as an outage
    /// whatever else the status says.
    public var isRunningOnBattery: Bool {
        contains(.onBattery) || contains(.forcedShutdown)
    }

    /// Conditions that must reach `powerd` immediately, never debounced.
    public var isCritical: Bool {
        contains(.forcedShutdown) || contains(.lowBattery)
    }
}

/// The single, well-typed reading the rest of Squirrel works from.
public struct UPSReading: Equatable, Sendable {
    public var upsName: String
    public var model: String?
    public var status: UPSStatusFlags
    /// `battery.charge`, percent.
    public var batteryCharge: Int?
    /// `battery.runtime`, seconds.
    public var batteryRuntime: Int?
    /// `ups.load`, percent.
    public var load: Int?
    /// Every variable the server reported, under NUT's own names.
    ///
    /// Kept whole because UPS hardware and drivers differ in what they report:
    /// the UI shows what this UPS actually sends rather than a fixed list with
    /// gaps in it.
    public var variables: [String: String]
    public var observedAt: Date

    public init(
        upsName: String,
        model: String? = nil,
        status: UPSStatusFlags,
        batteryCharge: Int? = nil,
        batteryRuntime: Int? = nil,
        load: Int? = nil,
        variables: [String: String] = [:],
        observedAt: Date = Date()
    ) {
        self.upsName = upsName
        self.model = model
        self.status = status
        self.batteryCharge = batteryCharge
        self.batteryRuntime = batteryRuntime
        self.load = load
        self.variables = variables
        self.observedAt = observedAt
    }

    /// Builds a reading from the raw variable dictionary `LIST VAR` returns.
    public init(upsName: String, variables: [String: String], observedAt: Date = Date()) {
        self.upsName = upsName
        self.model = variables["device.model"] ?? variables["ups.model"]
        self.status = UPSStatusFlags(statusString: variables["ups.status"] ?? "")
        self.batteryCharge = variables["battery.charge"].flatMap { Int(Double($0) ?? .nan) }
        self.batteryRuntime = variables["battery.runtime"].flatMap { Int(Double($0) ?? .nan) }
        self.load = variables["ups.load"].flatMap { Int(Double($0) ?? .nan) }
        self.variables = variables
        self.observedAt = observedAt
    }

    /// A reported variable, or nil when this UPS does not send it. Blank
    /// values count as absent: a driver that reports an empty string knows no
    /// more than one that reports nothing.
    public func value(_ key: String) -> String? {
        guard let value = variables[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    public func number(_ key: String) -> Double? {
        value(key).flatMap(Double.init)
    }

    /// A reading older than this must not be presented to macOS as the truth.
    public func isFresh(asOf now: Date = Date(), maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(observedAt) <= maxAge
    }
}
