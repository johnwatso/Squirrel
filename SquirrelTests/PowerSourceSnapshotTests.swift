import XCTest
import SquirrelCore

final class PowerSourceKeyTests: XCTestCase {
    /// The IOPSKeys.h constants are C `#define`s and do not bridge into Swift,
    /// so these literals are the contract with powerd. Each is copied from
    /// the SDK header; if one drifts, macOS silently ignores that field.
    func testKeyLiteralsMatchTheSDKHeader() {
        XCTAssertEqual(PSKey.name, "Name")
        XCTAssertEqual(PSKey.type, "Type")
        XCTAssertEqual(PSKey.transportType, "Transport Type")
        XCTAssertEqual(PSKey.state, "Power Source State")
        XCTAssertEqual(PSKey.currentCapacity, "Current Capacity")
        XCTAssertEqual(PSKey.maxCapacity, "Max Capacity")
        XCTAssertEqual(PSKey.timeToEmpty, "Time to Empty")
        XCTAssertEqual(PSKey.isPresent, "Is Present")
        XCTAssertEqual(PSKey.isCharging, "Is Charging")
        XCTAssertEqual(PSKey.internalFailure, "Internal Failure")
        XCTAssertEqual(PSValue.upsType, "UPS")
        XCTAssertEqual(PSValue.networkType, "Ethernet")
        XCTAssertEqual(PSValue.acPower, "AC Power")
        XCTAssertEqual(PSValue.batteryPower, "Battery Power")
    }
}

final class PowerSourceSnapshotTests: XCTestCase {
    private func reading(
        status: String,
        charge: Int? = 100,
        runtime: Int? = 1800,
        at date: Date = Date()
    ) -> UPSReading {
        UPSReading(
            upsName: "ups",
            model: "UniFi UPS 2U",
            status: UPSStatusFlags(statusString: status),
            batteryCharge: charge,
            batteryRuntime: runtime,
            observedAt: date
        )
    }

    func testOnlineReadingBecomesAnACPowerSource() {
        let snapshot = PowerSourceSnapshot.from(reading: reading(status: "OL"))
        XCTAssertEqual(snapshot.state, .acPower)
        XCTAssertTrue(snapshot.isPresent)
        XCTAssertEqual(snapshot.currentCapacity, 100)
    }

    func testOnBatteryReadingBecomesABatteryPowerSource() {
        let snapshot = PowerSourceSnapshot.from(reading: reading(status: "OB", charge: 42))
        XCTAssertEqual(snapshot.state, .batteryPower)
        XCTAssertEqual(snapshot.currentCapacity, 42)
    }

    /// Runtime reaches macOS in minutes; NUT reports seconds.
    func testRuntimeIsConvertedToMinutes() {
        let snapshot = PowerSourceSnapshot.from(reading: reading(status: "OB", runtime: 1680))
        XCTAssertEqual(snapshot.timeToEmptyMinutes, 28)
    }

    /// The rule that keeps us honest with powerd: a reading we can no longer
    /// vouch for is published as "not present", never as a healthy UPS.
    func testStaleReadingsArePublishedAsNotPresent() {
        let old = Date().addingTimeInterval(-120)
        let snapshot = PowerSourceSnapshot.from(
            reading: reading(status: "OL", at: old), maxAge: 30
        )
        XCTAssertFalse(snapshot.isPresent)
        XCTAssertEqual(snapshot.currentCapacity, 0)
    }

    func testAFreshReadingInsideTheWindowIsTrusted() {
        let recent = Date().addingTimeInterval(-5)
        let snapshot = PowerSourceSnapshot.from(
            reading: reading(status: "OL", at: recent), maxAge: 30
        )
        XCTAssertTrue(snapshot.isPresent)
    }

    func testReplaceBatteryIsReportedAsAnInternalFailure() {
        let snapshot = PowerSourceSnapshot.from(reading: reading(status: "OL RB"))
        XCTAssertTrue(snapshot.internalFailure)
    }

    func testCapacityIsClampedIntoRange() {
        XCTAssertEqual(PowerSourceSnapshot(name: "x", state: .acPower, currentCapacity: 140).currentCapacity, 100)
        XCTAssertEqual(PowerSourceSnapshot(name: "x", state: .acPower, currentCapacity: -5).currentCapacity, 0)
    }

    func testDisplayNameOverridesTheModel() {
        let snapshot = PowerSourceSnapshot.from(reading: reading(status: "OL"), displayName: "Rack UPS")
        XCTAssertEqual(snapshot.name, "Rack UPS")
    }

    func testUnavailableSnapshotNeverClaimsCharge() {
        let snapshot = PowerSourceSnapshot.unavailable(name: "Rack UPS")
        XCTAssertFalse(snapshot.isPresent)
        XCTAssertEqual(snapshot.currentCapacity, 0)
        XCTAssertNil(snapshot.timeToEmptyMinutes)
    }
}
