import AppIntents
import Foundation
import SquirrelCore

/// Read intents return values, not just dialog, so they chain in a Shortcuts
/// automation — "if the UPS goes on battery, shut down the NAS and text me" is
/// the whole reason this surface exists.
struct GetUPSStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get UPS Status"
    static let description = IntentDescription("Returns the current status of the monitored UPS.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let summary = try await SquirrelIntentBridge.statusSummary()
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct GetUPSBatteryLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Get UPS Battery Level"
    static let description = IntentDescription("Returns the UPS battery level as a percentage.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let level = try await SquirrelIntentBridge.batteryLevel()
        return .result(value: level, dialog: "The UPS is at \(level)%.")
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
    static let description = IntentDescription("Resumes monitoring and presents the UPS to macOS again.")
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

    var errorDescription: String? {
        switch self {
        case .appUnavailable: "Open Squirrel once before running this shortcut."
        case .noUPSConfigured: "No UPS is configured in Squirrel yet."
        case .noReading: "Squirrel has not read the UPS yet."
        }
    }
}

@MainActor
enum SquirrelIntentBridge {
    private static weak var appModel: AppModel?

    static func configure(with appModel: AppModel) {
        self.appModel = appModel
    }

    private static func resolve() throws -> (AppModel, UPSDevice) {
        guard let appModel else { throw SquirrelIntentError.appUnavailable }
        guard let device = appModel.settings.systemDevice ?? appModel.settings.devices.first else {
            throw SquirrelIntentError.noUPSConfigured
        }
        return (appModel, device)
    }

    static func statusSummary() throws -> String {
        let (appModel, device) = try resolve()
        guard let reading = appModel.monitor.state(for: device).reading else {
            throw SquirrelIntentError.noReading
        }
        let charge = reading.batteryCharge.map { "\($0)%" } ?? "unknown charge"
        let state = reading.status.isRunningOnBattery ? "on battery" : "on line power"
        return "\(device.displayName) is \(state) at \(charge)."
    }

    static func batteryLevel() throws -> Int {
        let (appModel, device) = try resolve()
        guard let level = appModel.monitor.state(for: device).reading?.batteryCharge else {
            throw SquirrelIntentError.noReading
        }
        return level
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
