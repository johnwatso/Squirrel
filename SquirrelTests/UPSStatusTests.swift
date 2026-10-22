import XCTest
import SquirrelCore

final class UPSStatusFlagsTests: XCTestCase {
    func testParsesTheCommonOnlineCase() {
        let status = UPSStatusFlags(statusString: "OL CHRG")
        XCTAssertTrue(status.contains(.online))
        XCTAssertTrue(status.contains(.charging))
        XCTAssertFalse(status.isRunningOnBattery)
        XCTAssertFalse(status.isCritical)
    }

    func testOnBatteryWithLowBatteryIsCritical() {
        let status = UPSStatusFlags(statusString: "OB LB")
        XCTAssertTrue(status.isRunningOnBattery)
        XCTAssertTrue(status.isCritical)
    }

    /// A forced shutdown from the server is an outage whatever else the status
    /// line says, and it must never be debounced.
    func testForcedShutdownCountsAsOnBatteryAndCritical() {
        let status = UPSStatusFlags(statusString: "OL FSD")
        XCTAssertTrue(status.isRunningOnBattery)
        XCTAssertTrue(status.isCritical)
    }

    func testIgnoresVendorSpecificTokensRatherThanFailing() {
        let status = UPSStatusFlags(statusString: "OB VENDORTHING LB")
        XCTAssertTrue(status.contains(.onBattery))
        XCTAssertTrue(status.contains(.lowBattery))
    }

    func testIsCaseInsensitiveAndToleratesExtraWhitespace() {
        let status = UPSStatusFlags(statusString: "  ol   chrg  ")
        XCTAssertTrue(status.contains(.online))
        XCTAssertTrue(status.contains(.charging))
    }

    func testAnEmptyStatusIsNotAnOutage() {
        XCTAssertFalse(UPSStatusFlags(statusString: "").isRunningOnBattery)
    }
}

final class UPSReadingTests: XCTestCase {
    private let variables = [
        "ups.status": "OB DISCHRG",
        "battery.charge": "87",
        "battery.runtime": "1680",
        "ups.load": "23",
        "device.model": "UniFi UPS 2U",
    ]

    func testBuildsAReadingFromNUTVariables() {
        let reading = UPSReading(upsName: "ups", variables: variables)
        XCTAssertEqual(reading.model, "UniFi UPS 2U")
        XCTAssertEqual(reading.batteryCharge, 87)
        XCTAssertEqual(reading.batteryRuntime, 1680)
        XCTAssertEqual(reading.load, 23)
        XCTAssertTrue(reading.status.isRunningOnBattery)
    }

    /// NUT drivers report these as floats as often as integers.
    func testAcceptsFloatFormattedNumbers() {
        let reading = UPSReading(upsName: "ups", variables: ["battery.charge": "99.0", "ups.load": "7.5"])
        XCTAssertEqual(reading.batteryCharge, 99)
        XCTAssertEqual(reading.load, 7)
    }

    func testMissingVariablesStayNilRatherThanDefaultingToZero() {
        let reading = UPSReading(upsName: "ups", variables: ["ups.status": "OL"])
        XCTAssertNil(reading.batteryCharge)
        XCTAssertNil(reading.batteryRuntime)
    }

    func testFreshnessIsMeasuredAgainstWhenTheReadingWasTaken() {
        let takenAt = Date()
        let reading = UPSReading(upsName: "ups", status: .init(statusString: "OL"), observedAt: takenAt)
        XCTAssertTrue(reading.isFresh(asOf: takenAt.addingTimeInterval(10), maxAge: 30))
        XCTAssertFalse(reading.isFresh(asOf: takenAt.addingTimeInterval(31), maxAge: 30))
    }
}
