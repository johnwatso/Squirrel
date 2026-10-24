import Foundation
import SquirrelCore
import os

/// Polls each configured UPS and keeps macOS's picture of the UPS up to date.
@MainActor
final class UPSMonitor: ObservableObject {
    @Published private(set) var states: [UUID: UPSConnectionState] = [:]
    @Published private(set) var lastUpdated: [UUID: Date] = [:]
    /// The most recent good reading, kept after the connection drops so the
    /// window can show the last known values as last known, not as nothing.
    @Published private(set) var lastReadings: [UUID: UPSReading] = [:]
    /// When macOS was last seen running the Mac from this UPS during an
    /// outage. The only real proof the integration works end to end, so it is
    /// recorded rather than inferred from the power source being present.
    @Published private(set) var protectionVerifiedAt: [UUID: Date] = [:]
    /// Instant commands the server advertises for each UPS, from `LIST CMD`.
    /// Actions are only offered when the UPS actually supports them.
    @Published private(set) var availableCommands: [UUID: [String]] = [:]
    @Published private(set) var isPaused = false
    /// Set when macOS no longer exposes the power source API, so the UI can say
    /// so plainly rather than silently degrading.
    @Published private(set) var systemIntegrationUnavailable = false
    @Published private(set) var busyDeviceIDs: Set<UUID> = []

    private let settings: SettingsStore
    private let publisher: PowerSourcePublisher
    private let sleepAssertion: SleepAssertionService
    private let notifications: NotificationService
    private let history: PowerHistory
    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "Monitor")

    private var restartGeneration = 0
    private var publicationOwner: UUID?
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: NUTClient] = [:]
    /// When the UPS was first seen on battery, for debouncing.
    private var onBatterySince: [UUID: Date] = [:]

    /// The last condition announced for each UPS, so notifications and events
    /// fire on a change and never on a poll.
    private var lastCondition: [UUID: NotificationService.Condition] = [:]
    /// The last power condition seen while connected. Kept through a lost
    /// connection, so an outage that started while Squirrel could not see the
    /// UPS is still recorded when it comes back, and one that did not is not.
    private var lastPowerCondition: [UUID: NotificationService.Condition] = [:]
    private var connectionLost: Set<UUID> = []
    /// When polling started failing, so one dropped packet is not an event.
    private var failingSince: [UUID: Date] = [:]

    private static let verifiedKey = "protectionVerifiedAt"

    init(
        settings: SettingsStore,
        publisher: PowerSourcePublisher,
        sleepAssertion: SleepAssertionService,
        notifications: NotificationService,
        history: PowerHistory
    ) {
        self.settings = settings
        self.publisher = publisher
        self.sleepAssertion = sleepAssertion
        self.notifications = notifications
        self.history = history
        self.systemIntegrationUnavailable = !publisher.isSupported
        let stored = UserDefaults.standard.dictionary(forKey: Self.verifiedKey) as? [String: Double] ?? [:]
        self.protectionVerifiedAt = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, Date(timeIntervalSince1970: value)) }
        })
    }

    func start() {
        guard !isPaused else { return }
        publicationOwner = settings.preferences.publishPowerSource ? settings.systemDevice?.id : nil
        for device in settings.devices where pollTasks[device.id] == nil {
            startPolling(device)
        }
    }

    func restart() {
        let nextOwner = settings.preferences.publishPowerSource ? settings.systemDevice?.id : nil
        let ownerChanged = publicationOwner != nextOwner
        stopAll()
        let generation = restartGeneration
        Task {
            guard generation == restartGeneration else { return }
            if ownerChanged {
                sleepAssertion.endHoldingAwake()
                await publisher.withdraw()
            }
            guard generation == restartGeneration, !isPaused else { return }
            start()
        }
    }

    /// Pausing withdraws the power source too: a paused monitor must not keep
    /// asserting a healthy UPS that nobody is watching.
    func pause() async {
        isPaused = true
        stopAll()
        await publisher.withdraw()
        sleepAssertion.endHoldingAwake()
    }

    func resume() {
        isPaused = false
        start()
    }

    func state(for device: UPSDevice) -> UPSConnectionState {
        states[device.id] ?? .idle
    }

    /// The live reading if there is one, otherwise the last one Squirrel had.
    func lastReading(for device: UPSDevice) -> UPSReading? {
        state(for: device).reading ?? lastReadings[device.id]
    }

    /// Drops everything Squirrel remembers about a UPS that is being removed.
    func forget(_ device: UPSDevice) {
        lastReadings[device.id] = nil
        lastUpdated[device.id] = nil
        states[device.id] = nil
        protectionVerifiedAt[device.id] = nil
        lastPowerCondition[device.id] = nil
        connectionLost.remove(device.id)
        saveVerification()
        history.removeHistory(for: device.id)
    }

    func commands(for device: UPSDevice) -> [String] {
        availableCommands[device.id] ?? []
    }

    func isBusy(_ device: UPSDevice) -> Bool {
        busyDeviceIDs.contains(device.id)
    }

    /// Runs a NUT instant command, such as `test.battery.start.quick`. A
    /// refusal is thrown to the caller rather than recorded as the UPS's
    /// state: the server turning down a command says nothing about whether
    /// the UPS itself is reachable, and polling carries on regardless.
    func runInstantCommand(_ name: String, on device: UPSDevice) async throws {
        guard let client = clients[device.id] else { throw NUTError.notConnected }
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        do {
            try await client.instantCommand(name, ups: device.upsName)
            log.notice("Ran \(name, privacy: .public) on \(device.displayName, privacy: .public)")
        } catch {
            log.error("\(name, privacy: .public) on \(device.displayName, privacy: .public) was refused: \(Self.describe(error), privacy: .public)")
            throw error
        }
    }

    private func stopAll() {
        restartGeneration &+= 1
        // A restart is not a power event: forget the last condition so
        // reconnecting does not announce a change that never happened.
        lastCondition.removeAll()
        failingSince.removeAll()
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
        for client in clients.values { Task { await client.abort() } }
        clients.removeAll()
        onBatterySince.removeAll()
        busyDeviceIDs.removeAll()
    }

    private func startPolling(_ device: UPSDevice) {
        let password = settings.password(for: device)
        let client = NUTClient(configuration: device.clientConfiguration(password: password))
        clients[device.id] = client
        let interval = device.pollInterval
        states[device.id] = .connecting

        pollTasks[device.id] = Task { [weak self] in
            defer { Task { await client.abort() } }
            var haveCommands = false
            while !Task.isCancelled {
                do {
                    try await client.connect()
                    let reading = try await client.reading(ups: device.upsName)
                    guard !Task.isCancelled else { break }
                    await self?.handle(reading: reading, for: device)
                    if !haveCommands {
                        let commands = (try? await client.listCommands(ups: device.upsName)) ?? []
                        self?.store(commands: commands, for: device)
                        haveCommands = true
                    }
                } catch {
                    // connect() reuses an existing transport. Discard the failed
                    // one so the next poll opens a fresh, authenticated socket.
                    await client.abort()
                    haveCommands = false
                    guard !Task.isCancelled else { break }
                    await self?.handle(error: error, for: device)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func store(commands: [String], for device: UPSDevice) {
        availableCommands[device.id] = commands
    }

    private func handle(reading: UPSReading, for device: UPSDevice) async {
        states[device.id] = .online(reading)
        lastUpdated[device.id] = reading.observedAt
        lastReadings[device.id] = reading
        failingSince[device.id] = nil
        history.record(reading, for: device.id)
        transition(to: Self.condition(for: reading), for: device, reading: reading)
        await updateSystem(with: reading, for: device)
    }

    // MARK: - Events

    /// The single place a change of condition is noticed. Both the event log
    /// and notifications hang off it, so they can never disagree.
    private func transition(to condition: NotificationService.Condition, for device: UPSDevice, reading: UPSReading?) {
        let previous = lastCondition[device.id]
        lastCondition[device.id] = condition
        recordEvents(for: condition, device: device, reading: reading)
        // Nothing to announce on the very first reading: the user has just
        // opened the app, and the window already says what is going on.
        guard let previous, previous != condition else { return }
        notifications.notify(from: previous, to: condition, for: device, reading: reading)
    }

    /// Connection and power are logged as two separate stories: losing sight
    /// of the UPS is not a power cut, and regaining it is not mains returning.
    private func recordEvents(for condition: NotificationService.Condition, device: UPSDevice, reading: UPSReading?) {
        let id = device.id
        if condition.isConnectionProblem {
            // Only a loss if there was a connection to lose.
            guard lastPowerCondition[id] != nil, !connectionLost.contains(id) else { return }
            connectionLost.insert(id)
            let detail = condition == .upsUnavailable
                ? "The NUT server lost contact with the UPS"
                : "The NUT server could not be reached"
            history.record(.communicationLost, for: id, detail: detail)
            return
        }

        let detail = reading.flatMap(Self.eventDetail)
        if connectionLost.remove(id) != nil {
            history.record(.communicationRestored, for: id)
        }
        let before = lastPowerCondition[id]
        lastPowerCondition[id] = condition
        guard let before, before != condition else { return }

        switch (before, condition) {
        case (.normal, .onBattery):
            history.record(.powerLost, for: id, detail: detail)
        case (.normal, .lowBattery):
            history.record(.powerLost, for: id, detail: detail)
            history.record(.lowBattery, for: id, detail: detail)
        case (.onBattery, .lowBattery):
            history.record(.lowBattery, for: id, detail: detail)
        case (.onBattery, .normal), (.lowBattery, .normal):
            history.record(.powerRestored, for: id, detail: detail)
        default:
            break
        }
    }

    private static func eventDetail(_ reading: UPSReading) -> String? {
        var parts: [String] = []
        if let charge = reading.batteryCharge { parts.append("\(charge)%") }
        if let runtime = reading.batteryRuntime, reading.status.isRunningOnBattery {
            parts.append("\(UPSTelemetry.duration(seconds: runtime)) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the user would want to be told about, as opposed to every flag the
    /// UPS reports.
    private static func condition(for reading: UPSReading) -> NotificationService.Condition {
        if reading.status.contains(.lowBattery) || reading.status.contains(.forcedShutdown) {
            return .lowBattery
        }
        return reading.status.isRunningOnBattery ? .onBattery : .normal
    }

    private func handle(error: Error, for device: UPSDevice) async {
        states[device.id] = .failed(Self.describe(error))
        let since = failingSince[device.id] ?? Date()
        failingSince[device.id] = since
        // One failed poll on a busy network is not worth a banner. Wait for
        // the problem to persist, unless there was never a connection at all.
        let grace = max(15, device.pollInterval * 2)
        if lastCondition[device.id] == nil || Date().timeIntervalSince(since) >= grace {
            transition(to: Self.connectionCondition(for: error), for: device, reading: nil)
        }
        log.error("\(device.displayName, privacy: .public): \(Self.describe(error), privacy: .public)")

        // Never leave macOS believing a stale reading. If this is the UPS the
        // Mac depends on, say "not present" rather than something reassuring.
        guard !Task.isCancelled, settings.systemDevice?.id == device.id, settings.preferences.publishPowerSource else { return }
        _ = try? await publisher.publish(.unavailable(name: device.displayName))
    }

    /// Applies the debounce and hands the result to macOS.
    private func updateSystem(with reading: UPSReading, for device: UPSDevice) async {
        guard !Task.isCancelled, settings.systemDevice?.id == device.id, settings.preferences.publishPowerSource else { return }

        var snapshot = PowerSourceSnapshot.from(
            reading: reading,
            displayName: device.displayName,
            maxAge: settings.preferences.readingMaxAge
        )

        if reading.status.isRunningOnBattery {
            let first = onBatterySince[device.id] ?? Date()
            onBatterySince[device.id] = first
            let elapsed = Date().timeIntervalSince(first)

            // FSD and low battery are never debounced: the server has already
            // decided, and delay here costs the Mac its shutdown window.
            let settled = reading.status.isCritical || elapsed >= settings.preferences.onBatteryDebounce
            if !settled {
                snapshot.state = .acPower
            } else if settings.preferences.preventSleepDuringOutage {
                sleepAssertion.beginHoldingAwake(reason: "\(device.displayName) is running on battery")
            }
        } else {
            onBatterySince[device.id] = nil
            sleepAssertion.endHoldingAwake()
        }

        do {
            try await publisher.publish(snapshot)
            systemIntegrationUnavailable = false
            if snapshot.state == .batteryPower {
                confirmProtection(for: device)
            }
        } catch PowerSourcePublisher.PublishError.symbolsUnavailable {
            systemIntegrationUnavailable = true
        } catch {
            log.error("Could not publish power source: \(String(describing: error), privacy: .public)")
        }
    }

    /// "The server is fine but has lost the UPS" and "the server is gone"
    /// need different fixes, so they are told apart.
    private static func connectionCondition(for error: Error) -> NotificationService.Condition {
        switch error as? NUTError {
        case .dataStale, .driverNotConnected, .unknownUPS: return .upsUnavailable
        default: return .serverUnavailable
        }
    }

    // MARK: - Verification

    /// Asks macOS, not Squirrel's own bookkeeping, whether the Mac is now
    /// running from this UPS. Only then has the integration been shown to
    /// work: macOS has accepted the outage and its shutdown rules are live.
    private func confirmProtection(for device: UPSDevice) {
        guard let entry = SystemPowerSources.publishedUPS(named: device.displayName),
              entry.state == PSValue.batteryPower else { return }
        // Once a minute is plenty; the date only needs to say which outage.
        if let last = protectionVerifiedAt[device.id], Date().timeIntervalSince(last) < 60 { return }
        protectionVerifiedAt[device.id] = Date()
        saveVerification()
    }

    private func saveVerification() {
        let stored = Dictionary(uniqueKeysWithValues: protectionVerifiedAt.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(stored, forKey: Self.verifiedKey)
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? NUTError else { return error.localizedDescription }
        return error.friendlyDescription
    }
}
