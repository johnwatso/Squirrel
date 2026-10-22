import Foundation

/// How much the menu bar icon says at a glance.
enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconOnly
    case percentageDuringOutage
    case alwaysPercentage

    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .percentageDuringOutage: return "Show percentage during an outage"
        case .alwaysPercentage: return "Always show percentage"
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var menuBarDisplay: MenuBarDisplay = .percentageDuringOutage

    /// A reading older than this stops being treated as the truth, and macOS is
    /// told the UPS is not present rather than handed stale data.
    var readingMaxAge: TimeInterval = 30

    /// How long "on battery" must persist before macOS is told. Protects
    /// against a one-second NUT blip flipping the Mac onto its UPS power
    /// profile. Never applied to FSD or low battery.
    var onBatteryDebounce: TimeInterval = 20

    /// Hold a power assertion while the UPS is on battery, so the Mac does not
    /// idle-sleep through an outage and miss its own shutdown threshold.
    var preventSleepDuringOutage: Bool = true

    /// Nil until the user shows or hides the sidebar themselves. Until then it
    /// follows the number of UPSes: one needs no sidebar, several do.
    var sidebarVisible: Bool?

    /// Collapsed the first time, then whatever the user left it as.
    var technicalInfoExpanded: Bool = false

    /// The master switch. The three below choose which kinds of change are
    /// worth a banner, so turning off connection noise keeps outage alerts.
    var showNotifications: Bool = true
    var notifyPowerChanges: Bool = true
    var notifyLowBattery: Bool = true
    var notifyConnectionProblems: Bool = true

    /// Publish a power source at all. Turning this off makes Squirrel a plain
    /// monitor, which is the fallback when macOS no longer exposes the API.
    var publishPowerSource: Bool = true

    init() {}

    /// Every key is optional on the way in. The synthesised decoder requires
    /// all of them, so adding a preference would silently reset every saved
    /// one to its default the next time an older copy of the settings loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        menuBarDisplay = value(.menuBarDisplay, defaults.menuBarDisplay)
        readingMaxAge = value(.readingMaxAge, defaults.readingMaxAge)
        onBatteryDebounce = value(.onBatteryDebounce, defaults.onBatteryDebounce)
        preventSleepDuringOutage = value(.preventSleepDuringOutage, defaults.preventSleepDuringOutage)
        sidebarVisible = try? container.decodeIfPresent(Bool.self, forKey: .sidebarVisible)
        technicalInfoExpanded = value(.technicalInfoExpanded, defaults.technicalInfoExpanded)
        showNotifications = value(.showNotifications, defaults.showNotifications)
        notifyPowerChanges = value(.notifyPowerChanges, defaults.notifyPowerChanges)
        notifyLowBattery = value(.notifyLowBattery, defaults.notifyLowBattery)
        notifyConnectionProblems = value(.notifyConnectionProblems, defaults.notifyConnectionProblems)
        publishPowerSource = value(.publishPowerSource, defaults.publishPowerSource)
    }
}
