import XCTest
import SquirrelCore
@testable import Squirrel

@MainActor
final class PowerHistoryTests: XCTestCase {
    private let device = UUID()

    private func reading(at date: Date, power: String? = nil, charge: Int = 100, status: String = "OL") -> UPSReading {
        var variables = ["ups.status": status, "battery.charge": String(charge)]
        variables["ups.realpower"] = power
        return UPSReading(upsName: "ups", variables: variables, observedAt: date)
    }

    /// Readings every few seconds become one averaged row per minute, written
    /// when the minute is over.
    func testAveragesEachMinuteIntoOneSample() async throws {
        let history = PowerHistory(inMemory: true)
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 600
        history.record(reading(at: Date(timeIntervalSince1970: minute + 5), power: "100"), for: device)
        history.record(reading(at: Date(timeIntervalSince1970: minute + 35), power: "140"), for: device)
        history.record(reading(at: Date(timeIntervalSince1970: minute + 65), power: "90"), for: device)
        try await waitForWrites(history)

        let samples = await history.samples(for: device, in: .day)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.power, 120)
        XCTAssertEqual(samples.first?.onBattery, false)
    }

    /// A UPS that does not report real power has a gap, not a zero.
    func testMissingMeasurementsStayMissing() async throws {
        let history = PowerHistory(inMemory: true)
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 600
        history.record(reading(at: Date(timeIntervalSince1970: minute + 5), charge: 80, status: "OB"), for: device)
        history.record(reading(at: Date(timeIntervalSince1970: minute + 65)), for: device)
        try await waitForWrites(history)

        let samples = await history.samples(for: device, in: .day)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertNil(sample.power)
        XCTAssertEqual(sample.charge, 80)
        XCTAssertTrue(sample.onBattery)
    }

    func testEventsComeBackNewestFirst() async throws {
        let history = PowerHistory(inMemory: true)
        history.record(.powerLost, for: device, at: Date().addingTimeInterval(-120))
        history.record(.powerRestored, for: device, at: Date().addingTimeInterval(-60))
        try await waitForWrites(history)

        let events = await history.events(for: device)
        XCTAssertEqual(events.map(\.kind), [.powerRestored, .powerLost])
    }

    func testRemovingAUPSDeletesItsHistory() async throws {
        let history = PowerHistory(inMemory: true)
        history.record(.powerLost, for: device)
        try await waitForWrites(history)
        history.removeHistory(for: device)
        try await waitForWrites(history)

        let events = await history.events(for: device)
        XCTAssertTrue(events.isEmpty)
    }

    /// Writes hop onto the store's actor; give them a moment to land.
    private func waitForWrites(_ history: PowerHistory) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

final class AppPreferencesTests: XCTestCase {
    /// Settings saved by an older Squirrel lack newer keys. They must keep
    /// what they do have rather than all resetting to defaults.
    func testOlderSettingsKeepTheirValues() throws {
        let json = #"{"menuBarDisplay":"alwaysPercentage","readingMaxAge":60,"sidebarVisible":false}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.menuBarDisplay, .alwaysPercentage)
        XCTAssertEqual(preferences.readingMaxAge, 60)
        XCTAssertEqual(preferences.sidebarVisible, false)
        XCTAssertTrue(preferences.notifyLowBattery)
    }

    func testSidebarFollowsTheDeviceCountUntilChosen() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(preferences.sidebarVisible)
    }
}

@MainActor
final class MacProtectionStatusTests: XCTestCase {
    private let device = UPSDevice(displayName: "Rack", host: "nas", upsName: "ups")
    private let entry = SystemPowerSources.Entry(
        name: "Rack", type: "UPS", transportType: "Ethernet",
        isPresent: true, currentCapacity: 100, state: "AC Power"
    )

    private func advice(level: Int? = 25, sleep: Int = 10) -> PowerProfileAdvisor.Advice {
        var advice = PowerProfileAdvisor.Advice()
        advice.sleepMinutes = sleep
        advice.haltLevelPercent = level
        advice.didReadThresholds = true
        return advice
    }

    private func evaluate(_ integration: AppModel.NativeIntegrationState, _ advice: PowerProfileAdvisor.Advice, keepAwake: Bool = true) -> MacProtectionStatus {
        var preferences = AppPreferences()
        preferences.preventSleepDuringOutage = keepAwake
        return MacProtectionStatus.evaluate(
            device: device, integration: integration, advice: advice,
            preferences: preferences, integrationUnavailable: false
        )
    }

    func testActiveNeedsBothRecognitionAndARule() {
        XCTAssertEqual(evaluate(.published(entry), advice()).level, .active)
        XCTAssertEqual(evaluate(.published(entry), advice(level: nil)).level, .attention)
        XCTAssertEqual(evaluate(.monitoringOnly, advice()).level, .attention)
    }

    /// Connected is not the same as protected: a lost connection is amber,
    /// never green.
    func testALostConnectionIsNotProtection() {
        XCTAssertEqual(evaluate(.disconnected("gone"), advice()).level, .attention)
    }

    func testUnreadableRulesAreNotReportedAsActive() {
        XCTAssertEqual(evaluate(.published(entry), PowerProfileAdvisor.Advice()).level, .attention)
    }

    func testAShortSleepTimerOnlyMattersWithoutKeepAwake() {
        XCTAssertEqual(evaluate(.published(entry), advice(sleep: 1), keepAwake: true).level, .active)
        XCTAssertEqual(evaluate(.published(entry), advice(sleep: 1), keepAwake: false).level, .attention)
    }
}
