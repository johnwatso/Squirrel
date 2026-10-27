import Foundation
import SquirrelCore

/// Turns a reading into the short strings and symbol names the menu bar uses,
/// kept out of the views so it can be reasoned about (and tested) on its own.
enum MenuBarPresentation {
    /// One-line summary: "Running on battery · 87% · 28 min left".
    static func summary(for state: UPSConnectionState, isPaused: Bool = false) -> String {
        switch state {
        case .online(let reading):
            return UPSStatusPresentation.summary(for: reading)
        case .failed(let message):
            return message
        case .connecting, .idle:
            return UPSAppearance.shortStatus(for: state, isPaused: isPaused)
        }
    }

    /// How strongly a menu row's symbol should speak. Colour is kept for
    /// status, so ordinary actions stay monochrome.
    enum Tone: Equatable {
        case positive
        case caution
        case critical
        case neutral
    }

    /// The coloured symbol and words at the top of the menu.
    struct StatusLine: Equatable {
        let title: String
        let symbol: String
        let tone: Tone
    }

    /// "On mains power" with a green bolt, "Low battery" with a red warning,
    /// and so on. Severity comes from the UPS's own flags, so the menu never
    /// invents its own idea of a low battery.
    static func powerStatus(for state: UPSConnectionState, isPaused: Bool = false) -> StatusLine {
        switch state {
        case .online(let reading):
            let tone: Tone = switch UPSStatusPresentation.severity(for: reading.status) {
            case .normal: .positive
            case .caution: .caution
            case .critical: .critical
            }
            let symbol = tone == .critical ? "exclamationmark.triangle.fill" : symbolName(for: state)
            return StatusLine(title: UPSStatusPresentation.headline(for: reading.status), symbol: symbol, tone: tone)
        case .failed:
            return StatusLine(title: UPSAppearance.shortStatus(for: state), symbol: "bolt.slash.fill", tone: .neutral)
        case .connecting:
            return StatusLine(title: UPSAppearance.shortStatus(for: state), symbol: "questionmark.circle", tone: .neutral)
        case .idle:
            return StatusLine(title: UPSAppearance.shortStatus(for: state, isPaused: isPaused), symbol: "pause.circle", tone: .neutral)
        }
    }

    /// One label and value in the menu's telemetry block.
    struct TelemetryRow: Equatable {
        let label: String
        let value: String
    }

    /// Battery, runtime and load, with the load's percentage and power on
    /// one row. Unsupported values are omitted and disconnected devices never
    /// inherit another UPS's data.
    static func telemetryRows(for state: UPSConnectionState) -> [TelemetryRow] {
        guard let reading = state.reading else { return [] }
        var rows: [TelemetryRow] = []
        if let charge = reading.batteryCharge {
            rows.append(TelemetryRow(label: "Battery", value: "\(charge)%"))
        }
        if let runtime = reading.batteryRuntime {
            rows.append(TelemetryRow(label: "Runtime", value: UPSTelemetry.duration(seconds: runtime)))
        }
        let load = [
            reading.load.map { "\($0)%" },
            UPSTelemetry.watts(reading) ?? UPSTelemetry.voltAmps(reading),
        ].compactMap { $0 }
        if !load.isEmpty {
            rows.append(TelemetryRow(label: "UPS Load", value: load.joined(separator: " · ")))
        }
        return rows
    }

    /// The macOS connection as one menu line: the Personal Hotspot symbol
    /// while macOS has the UPS, slashed while it doesn't. Green "Connected to
    /// macOS" only when the status is active: a reachable UPS is not enough.
    static func protectionLine(for status: MacProtectionStatus) -> StatusLine {
        let symbol = status.isConnected || status.level == .checking ? "personalhotspot" : disconnectedSymbol
        let tone: Tone = switch status.level {
        case .active: .positive
        case .attention: .caution
        case .notShared, .inactive, .checking: .neutral
        }
        return StatusLine(title: status.summary, symbol: symbol, tone: tone)
    }

    /// `personalhotspot.slash` is macOS 15+; earlier systems show the plain
    /// symbol, and the grey or orange tint and the words carry the state.
    private static var disconnectedSymbol: String {
        if #available(macOS 15, *) { return "personalhotspot.slash" }
        return "personalhotspot"
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

    /// A NUT instant command with the title the menu gives it.
    struct OfferedCommand: Equatable {
        let command: String
        let title: String
    }

    /// NUT lets anyone the server admits read a UPS, but only a signed-in
    /// user can send it commands, so commands are only offered for a UPS set
    /// up with a username.
    static func canRunCommands(on device: UPSDevice) -> Bool {
        device.username?.isEmpty == false
    }

    /// "Silence Alarm", for the top of the menu, while the UPS is sounding one:
    /// it is on battery or reporting a fault, and its beeper isn't already
    /// off. Mutes this alarm only; the beeper sounds again for the next one.
    static func alarmCommand(supported: [String], reading: UPSReading?, signedIn: Bool) -> OfferedCommand? {
        guard signedIn, supported.contains("beeper.mute"), let reading else { return nil }
        let alarming: UPSStatusFlags = [.onBattery, .lowBattery, .alarm, .overload, .replaceBattery, .forcedShutdown]
        guard !reading.status.isDisjoint(with: alarming) else { return nil }
        let beeper = reading.value("ups.beeper.status")?.lowercased()
        guard beeper != "disabled", beeper != "muted" else { return nil }
        return OfferedCommand(command: "beeper.mute", title: "Silence Alarm")
    }

    /// The Controls submenu: commands the UPS supports, with a sign-in, that
    /// make sense right now. Turning the beeper off only while it's on, and so
    /// on. Nothing that cuts power to the load is ever offered, and nothing
    /// that starts a battery test or calibration, which can drop the power to
    /// this Mac if the battery fails. Stopping one the UPS began on its own
    /// schedule is still offered while it runs.
    static func offeredCommands(supported: [String], reading: UPSReading?, signedIn: Bool) -> [OfferedCommand] {
        guard signedIn else { return [] }
        let status = reading?.status ?? []
        let calibrating = status.contains(.calibrating)
        let testRunning = reading?.value("ups.test.result")?.lowercased().contains("progress") == true
        let beeper = reading?.value("ups.beeper.status")?.lowercased()

        var commands: [OfferedCommand] = []
        func offer(_ command: String, _ title: String, when condition: Bool = true) {
            if condition, supported.contains(command) { commands.append(OfferedCommand(command: command, title: title)) }
        }
        offer("test.battery.stop", "Stop Self-Test", when: testRunning)
        offer("calibrate.stop", "Stop Calibration", when: calibrating)
        offer("test.panel.start", "Test Lights and Beeper")
        offer("beeper.disable", "Turn Off Beeper", when: beeper != "disabled")
        offer("beeper.enable", "Turn On Beeper", when: beeper != "enabled")
        return commands
    }

    /// What to tell the user when the server turns a command down, and whether
    /// changing the sign-in could fix it.
    static func commandRefusal(_ error: Error, commandTitle: String, username: String?) -> (title: String, message: String, offersSignIn: Bool) {
        guard let error = error as? NUTError, error.isAuthenticationProblem else {
            return ("Couldn't \(commandTitle.lowercasedFirstWord)", UPSMonitor.describe(error), false)
        }
        let who = username.map { "“\($0)”" } ?? "this user"
        return (
            "The server didn't let \(who) run that command",
            "Check the username and password, and that the user has permission to run commands (instcmds) in the server's upsd.users.",
            true
        )
    }
}

private extension String {
    /// "Run Quick Self-Test" → "run Quick Self-Test", for use mid-sentence.
    var lowercasedFirstWord: String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}
