import XCTest
@testable import SquirrelCore

final class MacTemperatureTests: XCTestCase {
    /// Names as an M1 Mac mini reports them.
    private let m1 = [
        "PMGR SOC Die Temp Sensor0", "SOC MTR Temp Sensor1", "pACC MTR Temp Sensor2", "eACC MTR Temp Sensor0",
        "GPU MTR Temp Sensor1", "PMU tdie1", "PMU tdev4", "PMU tcal", "NAND CH0 temp",
    ]

    func testPrefersTheDieAndClusterSensors() {
        XCTAssertEqual(MacTemperatureSensors.chipSensorNames(m1), [
            "PMGR SOC Die Temp Sensor0", "SOC MTR Temp Sensor1", "pACC MTR Temp Sensor2",
            "eACC MTR Temp Sensor0", "GPU MTR Temp Sensor1",
        ])
    }

    /// A chip without those still has the power manager's die sensors, but
    /// never its calibration constants or board sensors.
    func testFallsBackToThePowerManagersDieSensors() {
        XCTAssertEqual(MacTemperatureSensors.chipSensorNames(["PMU tdie1", "PMU tdie2", "PMU tcal", "PMU tdev1"]),
                       ["PMU tdie1", "PMU tdie2"])
        XCTAssertTrue(MacTemperatureSensors.chipSensorNames(["NAND CH0 temp"]).isEmpty)
    }

    /// The M1 has sensors reading −21 °C at room temperature.
    func testIgnoresImpossibleReadings() {
        XCTAssertEqual(MacTemperatureSensors.average([30, 34, -21.7, .nan]), 32)
        XCTAssertNil(MacTemperatureSensors.average([-21.7, 0]))
        XCTAssertNil(MacTemperatureSensors.average([]))
    }

    /// On this Mac the reading should be a real chip temperature, or nil
    /// where the sensors are not exposed (Intel, a virtual machine).
    func testReadsAPlausibleTemperatureOrNothing() {
        if let value = MacTemperatureSensors.shared.chipTemperature() {
            XCTAssertTrue((5...130).contains(value), "\(value) °C is not a running chip")
        }
    }
}
