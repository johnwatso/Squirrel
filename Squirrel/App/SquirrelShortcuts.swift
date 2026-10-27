import AppIntents
import Foundation
import SquirrelCore

/// A configured UPS, so a shortcut can name which one it means. Leaving the
/// parameter empty keeps the old behaviour: the UPS macOS sees, or the first.
struct UPSEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "UPS"
    static let defaultQuery = UPSEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct UPSEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [UPSEntity] {
        await SquirrelIntentBridge.devices().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [UPSEntity] {
        await SquirrelIntentBridge.devices()
    }
}

/// Read intents return values, not just dialog, so they chain in a Shortcuts
/// automation — "if the UPS goes on battery, shut down the NAS and text me" is
/// the whole reason this surface exists.
struct GetUPSStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get UPS Status"
    static let description = IntentDescription("Returns the current status of the monitored UPS.")
    static let openAppWhenRun = false

    @Parameter(title: "UPS")
    var ups: UPSEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get status of \(\.$ups)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let summary = try await SquirrelIntentBridge.statusSummary(for: ups?.id)
        return .result(value: summary, dialog: "\(summary)")
    }
}

/// The condition an automation actually branches on. Matching the words of
/// Get UPS Status would break the moment that sentence is reworded.
struct IsUPSOnBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Is UPS On Battery"
    static let description = IntentDescription("Returns true when the UPS is running on battery rather than line power.")
    static let openAppWhenRun = false

    @Parameter(title: "UPS")
    var ups: UPSEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Is \(\.$ups) on battery")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let (name, onBattery) = try await SquirrelIntentBridge.isOnBattery(for: ups?.id)
        let dialog: IntentDialog = onBattery ? "\(name) is on battery." : "\(name) is on line power."
        return .result(value: onBattery, dialog: dialog)
    }
}

struct GetUPSBatteryLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Get UPS Battery Level"
    static let description = IntentDescription("Returns the UPS battery level as a percentage.")
    static let openAppWhenRun = false

    @Parameter(title: "UPS")
    var ups: UPSEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get battery level of \(\.$ups)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let level = try await SquirrelIntentBridge.batteryLevel(for: ups?.id)
        return .result(value: level, dialog: "The UPS is at \(level)%.")
    }
}

/// Whole minutes, rounded down: "shut down the NAS under 5 minutes" should
/// never fire late because 4 minutes 50 seconds rounded up to 5.
struct GetUPSRuntimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get UPS Runtime Remaining"
    static let description = IntentDescription("Returns the UPS's estimated runtime on battery, in whole minutes.")
    static let openAppWhenRun = false

    @Parameter(title: "UPS")
    var ups: UPSEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get runtime remaining on \(\.$ups)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let minutes = try await SquirrelIntentBridge.runtimeMinutes(for: ups?.id)
        let dialog: IntentDialog = minutes == 1
            ? "The UPS has about 1 minute of runtime."
            : "The UPS has about \(minutes) minutes of runtime."
        return .result(value: minutes, dialog: dialog)
    }
}

/// The honest answer to "is the integration actually working?" — this reads
/// what macOS itself reports, not what Squirrel believes.
struct GetSystemPowerSourceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Mac Power Source"
    static let description = IntentDescription("Returns what macOS itself reports about the Mac's power source.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let summary = await SquirrelIntentBridge.systemPowerSourceSummary()
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct RefreshSquirrelIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Squirrel"
    static let description = IntentDescription("Reconnects to every UPS and reads it again now.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await SquirrelIntentBridge.refresh()
        return .result(dialog: "\(message)")
    }
}

struct PauseSquirrelIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Squirrel"
    static let description = IntentDescription("Stops monitoring and removes the UPS from macOS until resumed.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await SquirrelIntentBridge.pause()
        return .result(dialog: "\(message)")
    }
}

struct ResumeSquirrelIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Squirrel"
    static let description = IntentDescription("Resumes monitoring and shares the UPS with macOS again.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await SquirrelIntentBridge.resume()
        return .result(dialog: "\(message)")
    }
}

struct SquirrelAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetUPSStatusIntent(),
            phrases: ["Check \(.applicationName)", "What's my \(.applicationName) status"],
            shortTitle: "Check UPS",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: GetUPSBatteryLevelIntent(),
            phrases: ["\(.applicationName) battery level", "How charged is my \(.applicationName) UPS"],
            shortTitle: "UPS Battery Level",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: GetUPSRuntimeIntent(),
            phrases: ["\(.applicationName) runtime", "How long will my \(.applicationName) UPS last"],
            shortTitle: "UPS Runtime",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: GetSystemPowerSourceIntent(),
            phrases: ["What power source does \(.applicationName) see", "Check Mac power source with \(.applicationName)"],
            shortTitle: "Mac Power Source",
            systemImageName: "powerplug.fill"
        )
        AppShortcut(
            intent: PauseSquirrelIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Squirrel",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeSquirrelIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume Squirrel",
            systemImageName: "play.fill"
        )
    }
}

enum SquirrelIntentError: LocalizedError {
    case appUnavailable
    case noUPSConfigured
    case noReading
    case upsNotFound
    case noRuntime

    var errorDescription: String? {
        switch self {
        case .appUnavailable: "Open Squirrel once before running this shortcut."
        case .noUPSConfigured: "No UPS is configured in Squirrel yet."
        case .noReading: "Squirrel has not read the UPS yet."
        case .upsNotFound: "That UPS is no longer set up in Squirrel."
        case .noRuntime: "This UPS does not report its runtime."
        }
    }
}

@MainActor
enum SquirrelIntentBridge {
    private static weak var appModel: AppModel?

    static func configure(with appModel: AppModel) {
        self.appModel = appModel
    }

    static func devices() -> [UPSEntity] {
        appModel?.settings.devices.map { UPSEntity(id: $0.id, name: $0.displayName) } ?? []
    }

    /// A nil `id` means "whichever UPS the user would assume": the one macOS
    /// sees, or the first configured.
    private static func resolve(_ id: UUID? = nil) throws -> (AppModel, UPSDevice) {
        guard let appModel else { throw SquirrelIntentError.appUnavailable }
        if let id {
            guard let device = appModel.settings.device(id: id) else { throw SquirrelIntentError.upsNotFound }
            return (appModel, device)
        }
        guard let device = appModel.settings.systemDevice ?? appModel.settings.devices.first else {
            throw SquirrelIntentError.noUPSConfigured
        }
        return (appModel, device)
    }

    private static func currentReading(for id: UUID?) throws -> (UPSDevice, UPSReading) {
        let (appModel, device) = try resolve(id)
        guard let reading = appModel.monitor.state(for: device).reading else {
            throw SquirrelIntentError.noReading
        }
        return (device, reading)
    }

    static func statusSummary(for id: UUID? = nil) throws -> String {
        let (device, reading) = try currentReading(for: id)
        let charge = reading.batteryCharge.map { "\($0)%" } ?? "unknown charge"
        let state = reading.status.isRunningOnBattery ? "on battery" : "on line power"
        return "\(device.displayName) is \(state) at \(charge)."
    }

    static func isOnBattery(for id: UUID? = nil) throws -> (name: String, onBattery: Bool) {
        let (device, reading) = try currentReading(for: id)
        return (device.displayName, reading.status.isRunningOnBattery)
    }

    static func batteryLevel(for id: UUID? = nil) throws -> Int {
        guard let level = try currentReading(for: id).1.batteryCharge else {
            throw SquirrelIntentError.noReading
        }
        return level
    }

    static func runtimeMinutes(for id: UUID? = nil) throws -> Int {
        guard let seconds = try currentReading(for: id).1.batteryRuntime else {
            throw SquirrelIntentError.noRuntime
        }
        return seconds / 60
    }

    static func systemPowerSourceSummary() -> String {
        appModel?.systemUPSDescription ?? "Open Squirrel once before running this shortcut."
    }

    static func pause() async throws -> String {
        guard let appModel else { throw SquirrelIntentError.appUnavailable }
        await appModel.monitor.pause()
        return "Squirrel is paused and macOS no longer sees the UPS."
    }

    static func refresh() throws -> String {
        let (appModel, _) = try resolve()
        appModel.monitor.restart()
        appModel.refreshPowerProfileAdvice()
        return "Squirrel is polling the UPS now."
    }

    static func resume() throws -> String {
        guard let appModel else { throw SquirrelIntentError.appUnavailable }
        appModel.monitor.resume()
        return "Squirrel is monitoring again."
    }
}
