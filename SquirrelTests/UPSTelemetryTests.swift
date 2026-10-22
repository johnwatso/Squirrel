import XCTest
import SquirrelCore
@testable import Squirrel

final class UPSTelemetryTests: XCTestCase {
    private func reading(_ variables: [String: String]) -> UPSReading {
        UPSReading(upsName: "ups", variables: variables)
    }

    /// The whole point of reading variables dynamically: a UPS that does not
    /// report something gets no row for it, rather than a row reading zero.
    func testOnlyReportedValuesProduceRows() {
        let fields = UPSTelemetry.batteryFields(for: reading([
            "battery.charge": "100",
            "battery.voltage": "27.4",
        ]))
        XCTAssertEqual(fields.map(\.label), ["Charge", "Voltage"])
        XCTAssertFalse(fields.contains { $0.label == "Temperature" })
    }

    func testAUPSThatReportsNothingProducesNoRows() {
        XCTAssertTrue(UPSTelemetry.batteryFields(for: reading([:])).isEmpty)
        XCTAssertTrue(UPSTelemetry.electricalFields(for: reading([:])).isEmpty)
        XCTAssertTrue(UPSTelemetry.deviceFields(for: reading([:])).isEmpty)
    }

    /// A driver that reports an empty string knows no more than one that
    /// reports nothing at all.
    func testBlankValuesCountAsAbsent() {
        XCTAssertTrue(UPSTelemetry.deviceFields(for: reading(["ups.model": "   "])).isEmpty)
        XCTAssertNil(reading(["ups.serial": ""]).value("ups.serial"))
    }

    func testPrefersTheDeviceNamespaceOverTheUPSOne() {
        let fields = UPSTelemetry.deviceFields(for: reading([
            "device.model": "2U_1500VA_230V",
            "ups.model": "generic",
        ]))
        XCTAssertEqual(fields.first { $0.label == "Model" }?.value, "2U_1500VA_230V")
        XCTAssertEqual(fields.filter { $0.label == "Model" }.count, 1)
    }

    func testFallsBackToTheUPSNamespace() {
        let fields = UPSTelemetry.deviceFields(for: reading(["ups.mfr": "Ubiquiti"]))
        XCTAssertEqual(fields.first { $0.label == "Manufacturer" }?.value, "Ubiquiti")
    }

    func testValuesCarryTheirUnits() {
        let fields = UPSTelemetry.electricalFields(for: reading([
            "ups.load": "13",
            "ups.realpower": "130",
            "ups.power": "142.6",
            "input.voltage": "237.6",
            "input.frequency": "50.0",
        ]))
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.label, $0.value) })
        XCTAssertEqual(values["Load"], "13%")
        XCTAssertEqual(values["Real power"], "130 W")
        XCTAssertEqual(values["Apparent power"], "142.6 VA")
        XCTAssertEqual(values["Input voltage"], "237.6 V")
        // A whole number keeps no pointless decimal.
        XCTAssertEqual(values["Input frequency"], "50 Hz")
    }

    func testTemperatureIsADeviceDetail() {
        let fields = UPSTelemetry.deviceFields(for: reading(["ups.temperature": "28.5"]))
        XCTAssertEqual(fields.first { $0.label == "Temperature" }?.value, "28.5 °C")
    }

    func testIdentityNamesTheMakerAndSizeButNotTheNUTName() {
        let identity = UPSTelemetry.identity(for: UPSReading(upsName: "ups-rack", variables: [
            "device.mfr": "Ubiquiti",
            "ups.power.nominal": "1500",
            "device.model": "2U_1500VA_230V",
        ]))
        XCTAssertEqual(identity, "Ubiquiti · 1500 VA")
        XCTAssertNil(UPSTelemetry.identity(for: UPSReading(upsName: "ups-rack", variables: [:])))
    }

    func testRuntimeReadsAsAPersonWouldSayIt() {
        XCTAssertEqual(UPSTelemetry.duration(seconds: 0), "0 min")
        XCTAssertEqual(UPSTelemetry.duration(seconds: 2520), "42 min")
        XCTAssertEqual(UPSTelemetry.duration(seconds: 3600), "1 hr")
        XCTAssertEqual(UPSTelemetry.duration(seconds: 3840), "1 hr 4 min")
    }

    /// The raw variables must survive the trip from `LIST VAR`, or none of the
    /// dynamic rows can exist.
    func testTheRawVariablesAreKeptOnTheReading() {
        let parsed = UPSReading(upsName: "ups", variables: ["ups.status": "OL", "ups.load": "13"])
        XCTAssertEqual(parsed.value("ups.load"), "13")
        XCTAssertEqual(parsed.number("ups.load"), 13)
        XCTAssertNil(parsed.value("battery.temperature"))
    }
}

final class PowerManagementReportingTests: XCTestCase {
    private let sample = """
    UPS settings:
      haltlevel\ton\t25
      haltafter\toff\t1
      haltremain\ton\t10
    """

    func testReadsOnlyTheThresholdsThatAreSwitchedOn() {
        let advice = PowerProfileAdvisor.parse(pmsetUPSOutput: sample)
        XCTAssertEqual(advice.haltLevelPercent, 25)
        XCTAssertNil(advice.haltAfterMinutes)
        XCTAssertEqual(advice.haltRemainMinutes, 10)
        XCTAssertTrue(advice.didReadThresholds)
        XCTAssertTrue(advice.hasShutdownThreshold)
    }

    /// Unreadable is not the same as "none are set", and the UI must be able
    /// to tell the difference rather than guessing.
    func testUnreadableOutputIsNotMistakenForNothingBeingSet() {
        let advice = PowerProfileAdvisor.parse(pmsetUPSOutput: "")
        XCTAssertFalse(advice.didReadThresholds)
        XCTAssertFalse(advice.hasShutdownThreshold)
        XCTAssertFalse(advice.needsAttention(whenKeepingAwake: false))
    }

    func testAShortSleepTimerAloneIsNotAProblem() {
        var advice = PowerProfileAdvisor.parse(pmsetUPSOutput: "UPS settings:\n  haltlevel\toff\t0\n")
        advice.sleepMinutes = 1
        XCTAssertTrue(advice.sleepsTooSoon)
        // Nothing to miss: no shutdown threshold is set.
        XCTAssertFalse(advice.needsAttention(whenKeepingAwake: false))
    }

    func testAShortSleepTimerMattersOnlyWhenNothingHoldsTheMacAwake() {
        var advice = PowerProfileAdvisor.parse(pmsetUPSOutput: sample)
        advice.sleepMinutes = 1
        XCTAssertTrue(advice.needsAttention(whenKeepingAwake: false))
        XCTAssertFalse(advice.needsAttention(whenKeepingAwake: true))
    }

    func testAComfortableSleepTimerNeedsNoAttention() {
        var advice = PowerProfileAdvisor.parse(pmsetUPSOutput: sample)
        advice.sleepMinutes = 45
        XCTAssertFalse(advice.needsAttention(whenKeepingAwake: false))
    }
}
