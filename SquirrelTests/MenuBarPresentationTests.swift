import XCTest
import SquirrelCore
@testable import Squirrel

final class MenuBarPresentationTests: XCTestCase {
    private func state(_ status: String, charge: Int? = 100, runtime: Int? = 1800) -> UPSConnectionState {
        .online(UPSReading(
            upsName: "ups",
            model: "UniFi UPS 2U",
            status: UPSStatusFlags(statusString: status),
            batteryCharge: charge,
            batteryRuntime: runtime
        ))
    }

    func testSummaryReadsRuntimeDifferentlyOnMainsPower() {
        XCTAssertEqual(MenuBarPresentation.summary(for: state("OL")), "On mains power · 100% · 30 min runtime")
    }

    /// A UPS that does not report a runtime simply has no runtime in the line.
    func testSummaryOmitsWhatTheUPSDoesNotReport() {
        XCTAssertEqual(MenuBarPresentation.summary(for: state("OL", charge: nil, runtime: nil)), "On mains power")
    }

    func testSummaryShowsRuntimeDuringAnOutage() {
        XCTAssertEqual(
            MenuBarPresentation.summary(for: state("OB", charge: 87, runtime: 1680)),
            "Running on battery · 87% · 28 min left"
        )
    }

    func testTheMostUrgentStatusWins() {
        XCTAssertEqual(MenuBarPresentation.statusPhrase(for: .init(statusString: "OL FSD")), "Forced shutdown initiated")
        XCTAssertEqual(MenuBarPresentation.statusPhrase(for: .init(statusString: "OB LB")), "Low battery")
        XCTAssertEqual(MenuBarPresentation.statusPhrase(for: .init(statusString: "OL CHRG")), "On mains power")
    }

    func testFailureSummaryIsTheErrorItself() {
        XCTAssertEqual(MenuBarPresentation.summary(for: .failed("No route to host")), "No route to host")
    }

    func testIconTracksBatteryLevelDuringAnOutage() {
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB", charge: 95)), "battery.100")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB", charge: 70)), "battery.75")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB", charge: 50)), "battery.50")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB", charge: 20)), "battery.25")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB", charge: 5)), "battery.0")
    }

    func testIconIsABoltOnLinePowerAndAWarningWhenCritical() {
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OL")), "bolt.fill")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: state("OB LB")), "exclamationmark.triangle.fill")
        XCTAssertEqual(MenuBarPresentation.symbolName(for: .failed("x")), "bolt.slash.fill")
    }

    func testPercentageAppearsOnlyWhenTheChosenModeAsksForIt() {
        XCTAssertNil(MenuBarPresentation.menuBarText(for: state("OL"), display: .iconOnly))
        XCTAssertNil(MenuBarPresentation.menuBarText(for: state("OL"), display: .percentageDuringOutage))
        XCTAssertEqual(MenuBarPresentation.menuBarText(for: state("OB", charge: 42), display: .percentageDuringOutage), "42%")
        XCTAssertEqual(MenuBarPresentation.menuBarText(for: state("OL", charge: 99), display: .alwaysPercentage), "99%")
    }

    func testFlagsAreListedInPlainLanguage() {
        let flags = MenuBarPresentation.flagDescriptions(for: .init(statusString: "OB DISCHRG RB"))
        XCTAssertEqual(flags, ["Running on battery", "Replace battery", "Discharging"])
    }

    /// `ups.status` is a list, so a headline must not swallow what else the
    /// UPS is saying at the same time.
    func testSeveralSimultaneousFlagsAreAllReported() {
        let status = UPSStatusFlags(statusString: "OB DISCHRG LB RB")
        XCTAssertEqual(UPSStatusPresentation.headline(for: status), "Low battery")
        XCTAssertEqual(
            UPSStatusPresentation.conditions(for: status),
            ["Running on battery", "Replace battery", "Discharging"]
        )
        XCTAssertEqual(UPSStatusPresentation.severity(for: status), .critical)
    }

    func testSeveritySeparatesOrdinaryOperationFromTrouble() {
        XCTAssertEqual(UPSStatusPresentation.severity(for: .init(statusString: "OL CHRG")), .normal)
        XCTAssertEqual(UPSStatusPresentation.severity(for: .init(statusString: "OB")), .caution)
        XCTAssertEqual(UPSStatusPresentation.severity(for: .init(statusString: "OL RB")), .caution)
        XCTAssertEqual(UPSStatusPresentation.severity(for: .init(statusString: "OB LB")), .critical)
    }

    func testCommandsNeedASavedUsername() {
        var device = UPSDevice(displayName: "Rack", host: "10.0.0.2", upsName: "ups")
        XCTAssertFalse(MenuBarPresentation.canRunCommands(on: device))
        device.username = ""
        XCTAssertFalse(MenuBarPresentation.canRunCommands(on: device))
        device.username = "monuser"
        XCTAssertTrue(MenuBarPresentation.canRunCommands(on: device))
    }

    func testARefusedSignInOffersToChangeIt() {
        let refusal = MenuBarPresentation.commandRefusal(NUTError.accessDenied, commandTitle: "Run Quick Self-Test", username: "monuser")
        XCTAssertEqual(refusal.title, "The server didn't let “monuser” run that command")
        XCTAssertTrue(refusal.offersSignIn)
    }

    func testOtherCommandFailuresDoNotOfferASignIn() {
        let refusal = MenuBarPresentation.commandRefusal(NUTError.commandNotSupported, commandTitle: "Run Quick Self-Test", username: "monuser")
        XCTAssertEqual(refusal.title, "Couldn't run Quick Self-Test")
        XCTAssertEqual(refusal.message, "This UPS does not support that command.")
        XCTAssertFalse(refusal.offersSignIn)
    }

    private func reading(_ status: String, _ variables: [String: String] = [:]) -> UPSReading {
        UPSReading(upsName: "ups", variables: variables.merging(["ups.status": status]) { $1 })
    }

    private let everyCommand = [
        "test.battery.start.quick", "test.battery.start.deep", "test.battery.stop", "test.battery.start",
        "calibrate.start", "calibrate.stop", "test.panel.start",
        "beeper.mute", "beeper.disable", "beeper.enable", "load.off", "shutdown.return",
    ]

    func testNoCommandsAreOfferedWithoutASignIn() {
        XCTAssertEqual(MenuBarPresentation.offeredCommands(supported: everyCommand, reading: reading("OB"), signedIn: false), [])
        XCTAssertNil(MenuBarPresentation.alarmCommand(supported: everyCommand, reading: reading("OB"), signedIn: false))
    }

    func testSilenceAlarmAppearsOnlyWhileTheUPSIsAlarming() {
        XCTAssertEqual(MenuBarPresentation.alarmCommand(supported: everyCommand, reading: reading("OB DISCHRG"), signedIn: true)?.title, "Silence Alarm")
        XCTAssertNotNil(MenuBarPresentation.alarmCommand(supported: everyCommand, reading: reading("OL RB"), signedIn: true))
        XCTAssertNil(MenuBarPresentation.alarmCommand(supported: everyCommand, reading: reading("OL CHRG"), signedIn: true))
        XCTAssertNil(MenuBarPresentation.alarmCommand(supported: everyCommand, reading: reading("OB", ["ups.beeper.status": "muted"]), signedIn: true))
        XCTAssertNil(MenuBarPresentation.alarmCommand(supported: ["beeper.disable"], reading: reading("OB"), signedIn: true))
    }

    func testControlsFollowWhatTheUPSIsDoing() {
        let idle = MenuBarPresentation.offeredCommands(
            supported: everyCommand,
            reading: reading("OL", ["ups.test.result": "Done and passed", "ups.beeper.status": "enabled"]),
            signedIn: true
        ).map(\.title)
        XCTAssertEqual(idle, ["Test Lights and Beeper", "Turn Off Beeper"], "No battery test or calibration command is offered")

        let calibrating = MenuBarPresentation.offeredCommands(
            supported: everyCommand,
            reading: reading("OL CAL", ["ups.beeper.status": "disabled", "ups.test.result": "In progress"]),
            signedIn: true
        ).map(\.title)
        XCTAssertEqual(calibrating, ["Test Lights and Beeper", "Turn On Beeper"], "Not even the stop commands")
    }

    func testPowerStatusColoursFollowTheUPSsOwnSeverity() {
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: state("OL")), .init(title: "On mains power", symbol: "bolt.fill", tone: .positive))
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: state("OB", charge: 50)), .init(title: "Running on battery", symbol: "battery.50", tone: .caution))
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: state("OB LB", charge: 8)), .init(title: "Low battery", symbol: "exclamationmark.triangle.fill", tone: .critical))
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: .failed("No route to host")).tone, .neutral)
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: .connecting).symbol, "questionmark.circle")
    }

    /// Only an active status may be green; anything else is amber or grey.
    /// The hotspot is slashed whenever macOS doesn't have the UPS.
    func testConnectionLineIsGreenOnlyWhenActive() {
        let active = MacProtectionStatus(level: .active, title: "Connected", summary: "Connected to macOS", isConnected: true)
        XCTAssertEqual(MenuBarPresentation.protectionLine(for: active), .init(title: "Connected to macOS", symbol: "personalhotspot", tone: .positive))
        let noRule = MacProtectionStatus(level: .attention, title: "No Shutdown Rule", summary: "Connected · no shutdown rule", isConnected: true)
        XCTAssertEqual(MenuBarPresentation.protectionLine(for: noRule), .init(title: "Connected · no shutdown rule", symbol: "personalhotspot", tone: .caution))
        let unseen = MacProtectionStatus(level: .attention, title: "Not Detected", summary: "macOS can't see this UPS")
        XCTAssertEqual(MenuBarPresentation.protectionLine(for: unseen), .init(title: "macOS can't see this UPS", symbol: "personalhotspot.slash", tone: .caution))
        let notShared = MacProtectionStatus(level: .notShared, title: "Off", summary: "Not shared with macOS")
        XCTAssertEqual(MenuBarPresentation.protectionLine(for: notShared), .init(title: "Not shared with macOS", symbol: "personalhotspot.slash", tone: .neutral))
        let checking = MacProtectionStatus(level: .checking, title: "Checking…", summary: "Checking macOS connection…")
        XCTAssertEqual(MenuBarPresentation.protectionLine(for: checking), .init(title: "Checking macOS connection…", symbol: "personalhotspot", tone: .neutral))
    }

    /// The menu and the dashboard describe a lost or paused UPS in the same words.
    func testDisconnectedStatesShareOneVocabulary() {
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: .failed("No route to host")).title, "Not connected")
        XCTAssertEqual(UPSAppearance.shortStatus(for: .failed("No route to host")), "Not connected")
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: .idle, isPaused: true).title, "Paused")
        XCTAssertEqual(UPSAppearance.shortStatus(for: .idle, isPaused: true), "Paused")
        XCTAssertEqual(MenuBarPresentation.powerStatus(for: .idle).title, "Not monitoring")
        XCTAssertEqual(MenuBarPresentation.summary(for: .connecting), "Connecting…")
    }
}
