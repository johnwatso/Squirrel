import Foundation

/// The `IOPSKeys.h` constants are C preprocessor `#define`s, so they do not
/// bridge into Swift. These literal strings are the contract with `powerd`;
/// each one is copied from the SDK header and covered by a test.
public enum PSKey {
    public static let name           = "Name"
    public static let type           = "Type"
    public static let transportType  = "Transport Type"
    public static let powerSourceID  = "Power Source ID"
    public static let state          = "Power Source State"
    public static let currentCapacity = "Current Capacity"
    public static let maxCapacity    = "Max Capacity"
    public static let timeToEmpty    = "Time to Empty"
    public static let isPresent      = "Is Present"
    public static let isCharging     = "Is Charging"
    public static let internalFailure = "Internal Failure"
    public static let lowWarnLevel   = "Low Warn Level"
    public static let deadWarnLevel  = "Shutdown Level"
}

public enum PSValue {
    public static let upsType       = "UPS"
    public static let networkType   = "Ethernet"
    public static let acPower       = "AC Power"
    public static let batteryPower  = "Battery Power"
}

/// Everything macOS is told about our UPS, in one `Sendable` value.
///
/// Built outside the publisher and handed across actor isolation, so the
/// `CFDictionary` is only ever constructed inside `PowerSourcePublisher`.
public struct PowerSourceSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case acPower
        case batteryPower

        var psValue: String {
            switch self {
            case .acPower: return PSValue.acPower
            case .batteryPower: return PSValue.batteryPower
            }
        }
    }

    public var name: String
    public var state: State
    /// Percent remaining, 0...100.
    public var currentCapacity: Int
    public var maxCapacity: Int
    /// Minutes remaining, when the UPS gives an estimate.
    public var timeToEmptyMinutes: Int?
    public var isPresent: Bool
    public var isCharging: Bool
    /// Maps from the UPS reporting that its battery needs replacing.
    public var internalFailure: Bool

    public init(
        name: String,
        state: State,
        currentCapacity: Int,
        maxCapacity: Int = 100,
        timeToEmptyMinutes: Int? = nil,
        isPresent: Bool = true,
        isCharging: Bool = false,
        internalFailure: Bool = false
    ) {
        self.name = name
        self.state = state
        self.currentCapacity = max(0, min(currentCapacity, maxCapacity))
        self.maxCapacity = maxCapacity
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.isPresent = isPresent
        self.isCharging = isCharging
        self.internalFailure = internalFailure
    }

    /// The snapshot that says "there is a UPS configured, but I cannot vouch
    /// for what it is doing". Published instead of a stale reading, so
    /// `powerd` is never handed a cheerful lie.
    public static func unavailable(name: String) -> PowerSourceSnapshot {
        PowerSourceSnapshot(
            name: name,
            state: .acPower,
            currentCapacity: 0,
            timeToEmptyMinutes: nil,
            isPresent: false,
            isCharging: false
        )
    }

    /// Translates a NUT reading into what macOS should believe.
    ///
    /// - Parameter maxAge: a reading older than this is not trusted, and the
    ///   result is `.unavailable` regardless of how healthy the stale data looks.
    public static func from(
        reading: UPSReading,
        displayName: String? = nil,
        maxAge: TimeInterval = 30,
        now: Date = Date()
    ) -> PowerSourceSnapshot {
        let name = displayName ?? reading.model ?? reading.upsName
        guard reading.isFresh(asOf: now, maxAge: maxAge) else {
            return .unavailable(name: name)
        }
        return PowerSourceSnapshot(
            name: name,
            state: reading.status.isRunningOnBattery ? .batteryPower : .acPower,
            currentCapacity: reading.batteryCharge ?? 100,
            maxCapacity: 100,
            timeToEmptyMinutes: reading.batteryRuntime.map { max(0, $0 / 60) },
            isPresent: true,
            isCharging: reading.status.contains(.charging),
            internalFailure: reading.status.contains(.replaceBattery)
        )
    }

    /// The dictionary handed to `IOPSSetPowerSourceDetails`.
    ///
    /// Not `Sendable` by nature, so it is built inside the publisher's
    /// isolation and never crosses it.
    func dictionaryRepresentation() -> [String: Any] {
        var details: [String: Any] = [
            PSKey.name: name,
            PSKey.type: PSValue.upsType,
            PSKey.transportType: PSValue.networkType,
            PSKey.state: state.psValue,
            PSKey.currentCapacity: currentCapacity,
            PSKey.maxCapacity: maxCapacity,
            PSKey.isPresent: isPresent,
            PSKey.isCharging: isCharging,
        ]
        if let timeToEmptyMinutes {
            details[PSKey.timeToEmpty] = timeToEmptyMinutes
        }
        if internalFailure {
            details[PSKey.internalFailure] = true
        }
        return details
    }
}
