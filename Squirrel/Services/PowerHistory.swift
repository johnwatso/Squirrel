import Foundation
import SQLite3
import SquirrelCore
import os

/// One point on a history chart. Every measurement is optional because UPSes
/// differ in what they report: a missing value is a gap, never a zero.
struct PowerSample: Identifiable, Equatable, Sendable {
    var date: Date
    var power: Double?
    var load: Double?
    var charge: Double?
    var runtime: Double?
    /// True if the UPS was on battery at any point in this interval.
    var onBattery: Bool
    /// Degrees Celsius, from the UPS or else its battery. Few UPSes report it.
    var temperature: Double? = nil

    var id: Date { date }
}

/// The changes worth keeping a record of. Readings are not events: these are
/// the moments someone would ask about later ("when did the power go out?").
enum PowerEventKind: String, CaseIterable, Sendable {
    case powerLost
    case powerRestored
    case lowBattery
    case communicationLost
    case communicationRestored
    case scheduleChanged
    case systemWake
    case systemSleep
    case systemShutdown

    var title: String {
        switch self {
        case .powerLost: return "Mains power lost"
        case .powerRestored: return "Mains power restored"
        case .lowBattery: return "Battery low"
        case .communicationLost: return "UPS connection lost"
        case .communicationRestored: return "UPS connection restored"
        case .scheduleChanged: return "Power schedule updated"
        case .systemWake: return "Mac woke"
        case .systemSleep: return "Mac preparing to sleep"
        case .systemShutdown: return "Mac preparing to shut down"
        }
    }

    var provenance: String {
        switch self {
        case .systemWake, .systemSleep, .systemShutdown: return "Reported by macOS · Cause unverified"
        case .scheduleChanged: return "Configuration saved · Execution unverified"
        default: return "Observed by Squirrel"
        }
    }

    var symbolName: String {
        switch self {
        case .powerLost: return "bolt.slash.fill"
        case .powerRestored: return "bolt.fill"
        case .lowBattery: return "battery.25"
        case .communicationLost: return "wifi.exclamationmark"
        case .communicationRestored: return "wifi"
        case .scheduleChanged: return "calendar.badge.clock"
        case .systemWake: return "sun.max.fill"
        case .systemSleep: return "moon.fill"
        case .systemShutdown: return "power"
        }
    }
}

struct PowerEvent: Identifiable, Equatable, Sendable {
    var id: Int64
    var date: Date
    var kind: PowerEventKind
    var detail: String?
}

/// The spans the history sheet offers, each with a bucket size that keeps
/// the chart to a few hundred points however long the range.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24 Hours"
        case .week: return "7 Days"
        case .month: return "30 Days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }

    var bucket: TimeInterval {
        switch self {
        case .day: return 5 * 60
        case .week: return 30 * 60
        case .month: return 2 * 3600
        }
    }
}

/// Records what each UPS reported, a minute at a time, and the power events
/// between those minutes.
///
/// Fed by `UPSMonitor`'s existing poll rather than polling on its own. Readings
/// arrive every few seconds; they are averaged into one row per minute, so a
/// month of history for one UPS is about 43,000 small rows.
@MainActor
final class PowerHistory: ObservableObject {
    /// Changes whenever something new is written, so open charts reload.
    @Published private(set) var revision = 0

    static let sampleRetention: TimeInterval = 31 * 24 * 3600
    static let eventRetention: TimeInterval = 365 * 24 * 3600

    private let store: PowerHistoryStore?
    private var accumulators: [UUID: Accumulator] = [:]
    private var lastPrune = Date.distantPast
    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "History")

    init(inMemory: Bool = false) {
        let path = inMemory ? ":memory:" : Self.databaseURL()?.path
        store = path.flatMap { PowerHistoryStore(path: $0) }
        if store == nil {
            log.error("Power history is unavailable: the database could not be opened")
        }
    }

    var isAvailable: Bool { store != nil }

    // MARK: - Recording

    func record(_ reading: UPSReading, for deviceID: UUID) {
        let minute = Int(reading.observedAt.timeIntervalSince1970 / 60)
        if let pending = accumulators[deviceID], pending.minute != minute {
            flush(pending, for: deviceID)
            accumulators[deviceID] = nil
        }
        accumulators[deviceID, default: Accumulator(minute: minute)].add(reading)
    }

    func record(_ kind: PowerEventKind, for deviceID: UUID, detail: String? = nil, at date: Date = Date()) {
        guard let store else { return }
        Task {
            await store.insertEvent(device: deviceID, date: date, kind: kind, detail: detail)
            revision &+= 1
        }
    }

    func removeHistory(for deviceID: UUID) {
        accumulators[deviceID] = nil
        guard let store else { return }
        Task {
            await store.deleteAll(device: deviceID)
            revision &+= 1
        }
    }

    private func flush(_ accumulator: Accumulator, for deviceID: UUID) {
        guard let store else { return }
        let sample = accumulator.sample
        let prune = Date().timeIntervalSince(lastPrune) > 6 * 3600
        if prune { lastPrune = Date() }
        Task {
            await store.insertSample(device: deviceID, sample: sample)
            if prune {
                await store.prune(
                    samplesBefore: Date().addingTimeInterval(-Self.sampleRetention),
                    eventsBefore: Date().addingTimeInterval(-Self.eventRetention)
                )
            }
            revision &+= 1
        }
    }

    // MARK: - Reading

    func samples(for deviceID: UUID, in range: HistoryRange) async -> [PowerSample] {
        guard let store else { return [] }
        let since = Date().addingTimeInterval(-range.duration)
        return await store.samples(device: deviceID, since: since, bucket: range.bucket)
    }

    func events(for deviceID: UUID, since: Date? = nil, limit: Int = 200) async -> [PowerEvent] {
        guard let store else { return [] }
        return await store.events(device: deviceID, since: since ?? .distantPast, limit: limit)
    }

    private static func databaseURL() -> URL? {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.johnwatso.Squirrel", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("History.sqlite")
    }
}

/// Sums for one minute of readings, averaged when the minute ends.
private struct Accumulator {
    let minute: Int
    private var power = Mean()
    private var load = Mean()
    private var charge = Mean()
    private var runtime = Mean()
    private var temperature = Mean()
    private var onBattery = false

    init(minute: Int) {
        self.minute = minute
    }

    mutating func add(_ reading: UPSReading) {
        power.add(reading.number("ups.realpower"))
        load.add(reading.load.map(Double.init))
        charge.add(reading.batteryCharge.map(Double.init))
        runtime.add(reading.batteryRuntime.map(Double.init))
        temperature.add(reading.number("ups.temperature") ?? reading.number("battery.temperature"))
        onBattery = onBattery || reading.status.isRunningOnBattery
    }

    var sample: PowerSample {
        PowerSample(
            date: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
            power: power.value,
            load: load.value,
            charge: charge.value,
            runtime: runtime.value,
            onBattery: onBattery,
            temperature: temperature.value
        )
    }

    private struct Mean {
        private var sum = 0.0
        private var count = 0

        mutating func add(_ value: Double?) {
            guard let value, value.isFinite else { return }
            sum += value
            count += 1
        }

        var value: Double? { count > 0 ? sum / Double(count) : nil }
    }
}

// MARK: - Storage

/// SQLite through the system library: no dependency, nothing to run, and a
/// single file that survives Squirrel being quit or the Mac losing power.
actor PowerHistoryStore {
    /// Only touched from the actor, and by `deinit` once nothing else can.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "History")

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS samples (
                device TEXT NOT NULL,
                t REAL NOT NULL,
                power REAL,
                load REAL,
                charge REAL,
                runtime REAL,
                on_battery INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS samples_device_t ON samples(device, t);
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device TEXT NOT NULL,
                t REAL NOT NULL,
                kind TEXT NOT NULL,
                detail TEXT
            );
            CREATE INDEX IF NOT EXISTS events_device_t ON events(device, t);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              Self.migrate(handle) else {
            sqlite3_close(handle)
            return nil
        }
    }

    /// Columns added after the first release of the file. `user_version`
    /// records how far a database has come, so each step runs once.
    private static func migrate(_ handle: OpaquePointer?) -> Bool {
        var version: Int32 = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        if version < 1 {
            let step = "ALTER TABLE samples ADD COLUMN temperature REAL; PRAGMA user_version = 1;"
            guard sqlite3_exec(handle, step, nil, nil, nil) == SQLITE_OK else { return false }
        }
        return true
    }

    deinit {
        sqlite3_close(db)
    }

    func insertSample(device: UUID, sample: PowerSample) {
        run("INSERT INTO samples (device, t, power, load, charge, runtime, on_battery, temperature) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            bind(device.uuidString, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, sample.date.timeIntervalSince1970)
            bind(sample.power, at: 3, in: statement)
            bind(sample.load, at: 4, in: statement)
            bind(sample.charge, at: 5, in: statement)
            bind(sample.runtime, at: 6, in: statement)
            sqlite3_bind_int(statement, 7, sample.onBattery ? 1 : 0)
            bind(sample.temperature, at: 8, in: statement)
        }
    }

    func insertEvent(device: UUID, date: Date, kind: PowerEventKind, detail: String?) {
        run("INSERT INTO events (device, t, kind, detail) VALUES (?, ?, ?, ?)") { statement in
            bind(device.uuidString, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            bind(kind.rawValue, at: 3, in: statement)
            bind(detail, at: 4, in: statement)
        }
    }

    func prune(samplesBefore: Date, eventsBefore: Date) {
        run("DELETE FROM samples WHERE t < ?") { sqlite3_bind_double($0, 1, samplesBefore.timeIntervalSince1970) }
        run("DELETE FROM events WHERE t < ?") { sqlite3_bind_double($0, 1, eventsBefore.timeIntervalSince1970) }
    }

    func deleteAll(device: UUID) {
        run("DELETE FROM samples WHERE device = ?") { bind(device.uuidString, at: 1, in: $0) }
        run("DELETE FROM events WHERE device = ?") { bind(device.uuidString, at: 1, in: $0) }
    }

    /// Averages each bucket. `AVG` skips NULLs, so a UPS that stopped
    /// reporting a value mid-bucket does not drag the average towards zero.
    func samples(device: UUID, since: Date, bucket: TimeInterval) -> [PowerSample] {
        let sql = """
            SELECT CAST(t / ?1 AS INTEGER) * ?1 AS b, AVG(power), AVG(load), AVG(charge), AVG(runtime), MAX(on_battery), AVG(temperature)
            FROM samples WHERE device = ?2 AND t >= ?3
            GROUP BY b ORDER BY b
            """
        var result: [PowerSample] = []
        query(sql) { statement in
            sqlite3_bind_double(statement, 1, bucket)
            bind(device.uuidString, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        } row: { statement in
            result.append(PowerSample(
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                power: column(statement, 1),
                load: column(statement, 2),
                charge: column(statement, 3),
                runtime: column(statement, 4),
                onBattery: sqlite3_column_int(statement, 5) != 0,
                temperature: column(statement, 6)
            ))
        }
        return result
    }

    func events(device: UUID, since: Date, limit: Int) -> [PowerEvent] {
        var result: [PowerEvent] = []
        query("SELECT id, t, kind, detail FROM events WHERE device = ? AND t >= ? ORDER BY t DESC LIMIT ?") { statement in
            bind(device.uuidString, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(limit))
        } row: { statement in
            guard let raw = sqlite3_column_text(statement, 2),
                  let kind = PowerEventKind(rawValue: String(cString: raw)) else { return }
            let detail = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            result.append(PowerEvent(
                id: sqlite3_column_int64(statement, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: kind,
                detail: detail
            ))
        }
        return result
    }

    // MARK: - Statements

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) {
        query(sql, bind: bind, row: { _ in })
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            log.error("History query failed to prepare: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                row(statement)
            } else {
                if code != SQLITE_DONE {
                    log.error("History query failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                }
                return
            }
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ text: String?, at index: Int32, in statement: OpaquePointer) {
    guard let text else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_text(statement, index, text, -1, transient)
}

private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_double(statement, index, value)
}

private func column(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
}
