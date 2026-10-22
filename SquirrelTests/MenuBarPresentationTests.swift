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
}
