import SQLite3
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

    /// The Mac's chip is recorded beside the UPS, averaged over the minute
    /// like everything else, and missing rather than zero when unreadable.
    func testRecordsTheMacsTemperatureBesideTheUPS() async throws {
        let history = PowerHistory(inMemory: true, macTemperature: { 40 })
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 600
        history.record(reading(at: Date(timeIntervalSince1970: minute + 5)), for: device)
        history.record(reading(at: Date(timeIntervalSince1970: minute + 65)), for: device)
        try await waitForWrites(history)

        let samples = await history.samples(for: device, in: .day)
        XCTAssertEqual(samples.first?.macTemperature, 40)
        XCTAssertNil(samples.first?.temperature, "The UPS reported no temperature of its own")
    }

    /// Pausing or quitting must not lose the minute in progress, and the
    /// event saying why the readings stop lands with it.
    func testFinishingWritesTheMinuteInProgressAndTheReason() async throws {
        let history = PowerHistory(inMemory: true)
        let now = Date()
        history.record(reading(at: now, power: "75"), for: device)
        await history.finishWriting(recording: .monitoringStopped, for: [device])

        let samples = await history.samples(for: device, in: .day)
        XCTAssertEqual(samples.last?.power, 75)
        let events = await history.events(for: device)
        XCTAssertEqual(events.map(\.kind), [.monitoringStopped])
    }

    /// A history file from before Mac temperature gains the column and keeps
    /// what it had.
    func testOlderHistoryFilesGainTheMacTemperatureColumn() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SquirrelTests.History.\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let old = """
            CREATE TABLE samples (device TEXT NOT NULL, t REAL NOT NULL, power REAL, load REAL, charge REAL,
                runtime REAL, on_battery INTEGER NOT NULL DEFAULT 0, temperature REAL);
            INSERT INTO samples (device, t, power, on_battery, temperature) VALUES ('\(device.uuidString)', \(Date().timeIntervalSince1970 - 300), 50, 0, 24);
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(handle, old, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let store = try XCTUnwrap(PowerHistoryStore(path: url.path))
        await store.insertSample(device: device, sample: PowerSample(date: Date(), onBattery: false, macTemperature: 33))
        let samples = await store.samples(device: device, since: .distantPast, bucket: 60)
        XCTAssertEqual(samples.map(\.temperature), [24, nil])
        XCTAssertEqual(samples.map(\.macTemperature), [nil, 33])
    }

    /// Back-to-back repeats fold into one row; anything in between, or a
    /// different detail, keeps them apart.
    func testRepeatedEventsFoldIntoOneRow() {
        let now = Date()
        func event(_ id: Int64, _ kind: PowerEventKind, _ detail: String? = nil) -> PowerEvent {
            PowerEvent(id: id, date: now.addingTimeInterval(-Double(id) * 60), kind: kind, detail: detail)
        }
        let runs = EventRun.runs(from: [
            event(1, .monitoringStarted), event(2, .monitoringStarted), event(3, .powerRestored, "100%"),
            event(4, .monitoringStarted), event(5, .connectionUnstable, "Dropped 3 times"), event(6, .connectionUnstable, "Dropped 4 times"),
        ])
        XCTAssertEqual(runs.map(\.events.count), [2, 1, 1, 1, 1])
    }

    /// Hovering picks the closest reading, but not across a gap in the
    /// recording, and not one with nothing to show for this chart.
    func testHoverPicksTheClosestRecordedReading() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            PowerSample(date: start, power: 100, onBattery: false),
            PowerSample(date: start.addingTimeInterval(300), power: nil, onBattery: false),
            PowerSample(date: start.addingTimeInterval(600), power: 120, onBattery: false),
        ]
        let nearest = { (offset: TimeInterval) in
            HistoryChart.nearest(to: start.addingTimeInterval(offset), in: samples, metric: .power, within: 450)?.power
        }
        XCTAssertEqual(nearest(100), 100)
        XCTAssertEqual(nearest(320), 120, "The middle sample has no power to show")
        XCTAssertNil(nearest(2_000), "Past the last reading is a gap, not that reading")
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

    /// Connected follows macOS seeing the UPS, even while a rule is missing.
    func testConnectedMeansMacOSSeesTheUPS() {
        XCTAssertTrue(evaluate(.published(entry), advice()).isConnected)
        XCTAssertTrue(evaluate(.published(entry), advice(level: nil)).isConnected)
        XCTAssertFalse(evaluate(.monitoringOnly, advice()).isConnected)
        XCTAssertFalse(evaluate(.disconnected("gone"), advice()).isConnected)
    }

    func testUnreadableRulesAreNotReportedAsActive() {
        XCTAssertEqual(evaluate(.published(entry), PowerProfileAdvisor.Advice()).level, .attention)
    }

    func testAShortSleepTimerOnlyMattersWithoutKeepAwake() {
        XCTAssertEqual(evaluate(.published(entry), advice(sleep: 1), keepAwake: true).level, .active)
        XCTAssertEqual(evaluate(.published(entry), advice(sleep: 1), keepAwake: false).level, .attention)
    }
}
