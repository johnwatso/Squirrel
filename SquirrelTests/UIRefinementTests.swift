import XCTest
import SquirrelCore
@testable import Squirrel

final class UIRefinementTests: XCTestCase {
    func testFreshnessExpiresEvenIfConnectionStillSaysOnline() {
        let now = Date(timeIntervalSince1970: 1000)
        let freshness = ReadingFreshness(updated: now.addingTimeInterval(-31), isLive: true, maxAge: 30)
        XCTAssertFalse(freshness.isFresh(at: now))
        XCTAssertTrue(freshness.text(at: now).contains("stale"))
        XCTAssertTrue(ReadingFreshness(updated: now.addingTimeInterval(-30), isLive: true, maxAge: 30).isFresh(at: now))
    }

    func testDisconnectedAndMissingReadingsCannotLookFresh() {
        let now = Date()
        XCTAssertFalse(ReadingFreshness(updated: now, isLive: false, maxAge: 30).isFresh(at: now))
        let missing = ReadingFreshness(updated: nil, isLive: true, maxAge: 30)
        XCTAssertFalse(missing.isFresh(at: now))
        XCTAssertEqual(missing.text(at: now), "No reading yet")
    }

    func testMenuMeasurementsUseReportedValuesAndOmitUnsupportedOnes() {
        let reading = UPSReading(upsName: "rack", variables: [
            "ups.status": "OL", "battery.charge": "87", "battery.runtime": "3780",
            "ups.realpower": "140", "ups.load": "14"
        ])
        XCTAssertEqual(MenuBarPresentation.measurementLines(for: .online(reading)), [
            "Battery: 87%", "Runtime: 1 hr 3 min", "Power: 140 W", "Load: 14%"
        ])
        XCTAssertEqual(MenuBarPresentation.measurementLines(for: .failed("Offline")), [])
        XCTAssertEqual(MenuBarPresentation.measurementLines(for: .online(UPSReading(upsName: "minimal", variables: ["ups.status": "OL"]))), [])
    }

    func testApparentPowerIsNotMislabelledAsWatts() {
        let reading = UPSReading(upsName: "ups", variables: ["ups.power": "200"])
        XCTAssertEqual(MenuBarPresentation.measurementLines(for: .online(reading)), ["Apparent power: 200 VA"])
    }

    @MainActor
    func testSparkleRequiresSquirrelsOwnValidFeedAndKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(AppUpdater.isValidConfiguration(feed: "https://example.com/appcast.xml", publicKey: key))
        XCTAssertFalse(AppUpdater.isValidConfiguration(feed: "", publicKey: key))
        XCTAssertFalse(AppUpdater.isValidConfiguration(feed: "http://example.com/appcast.xml", publicKey: key))
        XCTAssertFalse(AppUpdater.isValidConfiguration(feed: "https://example.com/appcast.xml", publicKey: ""))
        XCTAssertFalse(AppUpdater.isValidConfiguration(feed: "$(SPARKLE_FEED_URL)", publicKey: "$(SPARKLE_PUBLIC_ED_KEY)"))
    }

    func testHistoryKeepsDevicesAndEventsSeparate() async throws {
        let store = try XCTUnwrap(PowerHistoryStore(path: ":memory:"))
        let rack = UUID(), office = UUID()
        let now = Date()
        await store.insertSample(device: rack, sample: PowerSample(date: now, power: 140, load: 14, charge: 100, runtime: 3780, onBattery: false))
        await store.insertSample(device: office, sample: PowerSample(date: now, power: 60, load: 6, charge: 80, runtime: 1800, onBattery: true))
        await store.insertEvent(device: rack, date: now, kind: .powerRestored, detail: nil)
        await store.insertEvent(device: office, date: now, kind: .powerLost, detail: nil)
        let rackSamples = await store.samples(device: rack, since: now.addingTimeInterval(-60), bucket: 300)
        let officeSamples = await store.samples(device: office, since: now.addingTimeInterval(-60), bucket: 300)
        let rackEvents = await store.events(device: rack, since: .distantPast, limit: 10)
        let officeEvents = await store.events(device: office, since: .distantPast, limit: 10)
        XCTAssertEqual(rackSamples.first?.power, 140)
        XCTAssertEqual(officeSamples.first?.power, 60)
        XCTAssertEqual(rackEvents.map(\.kind), [.powerRestored])
        XCTAssertEqual(officeEvents.map(\.kind), [.powerLost])
    }
}
