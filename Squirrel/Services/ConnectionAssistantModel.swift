import Foundation
import SquirrelCore
import os

/// One UPS a NUT server serves, with the live reading that proves it is real.
struct UPSCandidate: Identifiable, Equatable {
    let name: String
    /// The `LIST UPS` description. upsd answers "Unavailable" when the admin
    /// never set one, which is not worth showing.
    let serverDescription: String?
    let reading: UPSReading?

    var id: String { name }

    /// The best name we can give this UPS from what it reports.
    var title: String {
        if let suggested = UPSNaming.suggestedName(for: reading) { return suggested }
        if let serverDescription, !serverDescription.isEmpty { return serverDescription }
        return name
    }

    /// Present power state, when the UPS reported one.
    var statusPhrase: String? {
        guard let reading else { return nil }
        return MenuBarPresentation.statusPhrase(for: reading.status)
    }
}

/// One step of the real work of connecting, as the user sees it.
struct ConnectionStage: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case reachServer
        case authenticate
        case readUPS
        case publish
        case verify

        var title: String {
            switch self {
            case .reachServer: return "Connecting to the NUT server"
            case .authenticate: return "Authenticating"
            case .readUPS: return "Reading UPS information"
            case .publish: return "Publishing the UPS to macOS"
            case .verify: return "Checking that macOS sees it"
            }
        }
    }

    enum Status: Equatable {
        case pending
        case running
        case succeeded
        /// Ran, but there was nothing to do — an unauthenticated server, say.
        case skipped(String)
        case failed(String)
    }

    let kind: Kind
    var status: Status = .pending

    var id: Kind { kind }
}

/// Drives the connection assistant: every screen's state, and all of the
/// networking behind it, kept out of the views.
///
/// The one rule carried over from the first version: the user is never asked
/// to type the UPS name. Squirrel connects, enumerates with `LIST UPS`, and
/// shows a live reading beside each before anything is saved.
@MainActor
final class ConnectionAssistantModel: ObservableObject {
    enum Step: Equatable {
        case welcome
        case find
        case manual
        case select
        case connecting
        case finished
    }

    /// What the assistant ended up achieving. These are three different
    /// things and the last screen says which one happened.
    enum Outcome: Equatable {
        /// Reading the UPS and macOS has accepted it as a power source.
        case published
        /// Reading the UPS, but macOS is not treating it as a power source.
        case connectedOnly(String)
        case failed(String)
    }

    @Published var step: Step
    @Published var host = ""
    @Published var port = String(NUTProtocol.defaultPort)
    @Published var username = ""
    @Published var password = ""
    @Published var showsAuthentication = false
    @Published var showsAdvanced = false

    @Published private(set) var isValidating = false
    @Published private(set) var validationError: String?
    @Published private(set) var candidates: [UPSCandidate] = []
    @Published var selectedUPSName: String? {
        didSet { if !nameEdited { proposedName = suggestedName(for: selectedCandidate) } }
    }

    /// What the UPS will be called. Starts as a suggestion and becomes the
    /// user's own the moment they type in it.
    @Published private(set) var proposedName = ""
    private var nameEdited = false

    /// The kind of server this is, once something it reported gives it away.
    @Published private(set) var serverKind: NUTServerKind?
    /// The server turned this Mac away by address: a permitted-list problem
    /// on the server, which no username fixes.
    @Published private(set) var isRefusedByServer = false
    private(set) var serverHostName: String?

    @Published private(set) var stages: [ConnectionStage] = []
    @Published private(set) var outcome: Outcome?
    @Published private(set) var connectedDevice: UPSDevice?
    @Published private(set) var capturedReading: UPSReading?

    let discovery: NUTDiscoveryService
    private let settings: SettingsStore
    private let monitor: UPSMonitor
    private let publisher: PowerSourcePublisher
    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "Assistant")

    /// The device being reconfigured, so an edit updates it instead of adding
    /// a second copy of the same UPS.
    private let editingDeviceID: UUID?

    /// How long macOS gets to accept and then report the power source. Both
    /// are polls of real state, never a timer standing in for one.
    private let publishTimeout: TimeInterval = 10
    private let verifyTimeout: TimeInterval = 10

    init(
        settings: SettingsStore,
        monitor: UPSMonitor,
        publisher: PowerSourcePublisher,
        discovery: NUTDiscoveryService,
        editing device: UPSDevice? = nil
    ) {
        self.settings = settings
        self.monitor = monitor
        self.publisher = publisher
        self.discovery = discovery
        self.editingDeviceID = device?.id

        if let device {
            // Reconfiguring a UPS starts from what it is set to now.
            _step = Published(initialValue: .manual)
            _host = Published(initialValue: device.host)
            _port = Published(initialValue: String(device.port))
            _username = Published(initialValue: device.username ?? "")
            _password = Published(initialValue: settings.password(for: device) ?? "")
            _showsAuthentication = Published(initialValue: device.username?.isEmpty == false)
            _showsAdvanced = Published(initialValue: device.port != NUTProtocol.defaultPort)
            // Reconnecting keeps the name the UPS already has.
            _proposedName = Published(initialValue: device.displayName)
            nameEdited = true
        } else {
            // The welcome introduces Squirrel, so only a first setup sees it.
            // Adding another UPS goes straight to finding it.
            startsAtWelcome = settings.devices.isEmpty
            _step = Published(initialValue: startsAtWelcome ? .welcome : .find)
        }
    }

    var isEditing: Bool { editingDeviceID != nil }

    private var startsAtWelcome = false

    /// The window's title: setting Squirrel up, adding to it, or changing
    /// a UPS it already has.
    var windowTitle: String {
        if isEditing { return "Change UPS" }
        return startsAtWelcome ? "Set Up Squirrel" : "Add a UPS"
    }

    /// Where the server came from: the network search or a typed address.
    /// Back and recoverable errors return there, so someone who used the
    /// search is never dropped onto the manual form unless they must type
    /// something (a sign-in) to go on.
    private var serverSource: Step = .find

    /// Which of the three dots at the top is lit. The welcome and finished
    /// screens carry no navigation of their own.
    var progressIndex: Int? {
        switch step {
        case .welcome: return nil
        case .find, .manual: return 0
        case .select: return 1
        case .connecting, .finished: return 2
        }
    }

    var isConnecting: Bool {
        step == .connecting && outcome == nil
    }

    var selectedCandidate: UPSCandidate? {
        candidates.first { $0.name == selectedUPSName }
    }

    /// The UPS name the finished screen is talking about.
    var connectedTitle: String {
        connectedDevice?.displayName ?? selectedCandidate?.title ?? "Your UPS"
    }

    /// Live telemetry for the finished screen, preferring what the monitor is
    /// reading now over the reading captured while connecting. Never a stand-in.
    var summaryReading: UPSReading? {
        if let device = connectedDevice, let live = monitor.state(for: device).reading {
            return live
        }
        return capturedReading
    }

    // MARK: - Naming

    func editName(_ name: String) {
        proposedName = name
        nameEdited = true
    }

    /// From the UPS itself first; failing that, from the server it hangs off,
    /// such as "UPS on DiskStation".
    func suggestedName(for candidate: UPSCandidate?) -> String {
        guard let candidate else { return "" }
        // A UPS Squirrel already has keeps the name it was given.
        if let existing = existingDevice(for: candidate) { return existing.displayName }
        if let name = UPSNaming.suggestedName(for: candidate.reading) { return name }
        if let description = candidate.serverDescription, !description.isEmpty { return description }
        if let kind = serverKind, kind != .unifi { return "UPS on \(serverHostName ?? kind.title)" }
        return candidate.name
    }

    // MARK: - Already added

    /// The configured UPS this candidate already is, when connecting would
    /// update it rather than add a second one. Never the UPS being edited:
    /// reconnecting that one is the point.
    func existingDevice(for candidate: UPSCandidate) -> UPSDevice? {
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return nil }
        return existingDevice(host: host.trimmingCharacters(in: .whitespaces), port: port, upsName: candidate.name)
    }

    /// Whether every UPS a found server offers is one Squirrel already has.
    func isAlreadyAdded(_ server: DiscoveredNUTServer) -> Bool {
        !server.upsNames.isEmpty && server.upsNames.allSatisfy {
            existingDevice(host: server.host, port: server.port, upsName: $0) != nil
        }
    }

    private func existingDevice(host: String, port: UInt16, upsName: String) -> UPSDevice? {
        settings.devices.first {
            $0.id != editingDeviceID && $0.host.caseInsensitiveCompare(host) == .orderedSame
                && $0.port == port && $0.upsName == upsName
        }
    }

    // MARK: - Server help

    /// What to do about a server that turned this Mac away, with this Mac's
    /// real address in it.
    var accessHelp: String? {
        guard isRefusedByServer else { return nil }
        let address = NUTDiscovery.localAddress(toward: host.trimmingCharacters(in: .whitespaces))
        return serverKind?.accessInstructions(macAddress: address)
            ?? NUTServerKind.genericAccessInstructions(macAddress: address)
    }

    /// Fills in the fixed credentials a NAS uses for its UPS server.
    func useDefaultCredentials(of kind: NUTServerKind) {
        guard let credentials = kind.defaultCredentials else { return }
        username = credentials.username
        password = credentials.password
        showsAuthentication = true
        serverKind = serverKind ?? kind
    }

    // MARK: - Navigation

    func beginFinding() {
        step = .find
        validationError = nil
        discovery.startIfNeeded()
    }

    func chooseManualEntry() {
        serverSource = .manual
        step = .manual
        validationError = nil
    }

    func back() {
        validationError = nil
        switch step {
        case .find:
            guard startsAtWelcome else { return }
            discovery.stop()
            step = .welcome
        case .manual:
            guard !isEditing else { return }
            step = .find
        case .select:
            step = isEditing ? .manual : serverSource
        default:
            break
        }
    }

    var canGoBack: Bool {
        switch step {
        case .find: return startsAtWelcome
        case .manual: return !isEditing
        case .select: return true
        default: return false
        }
    }

    /// Fills in a server the scan found and goes straight on to enumerate it.
    func use(_ server: DiscoveredNUTServer) async {
        serverSource = .find
        host = server.host
        port = String(server.port)
        serverHostName = server.hostName
        serverKind = NUTServerKind.detect(
            hostName: server.hostName,
            upsNames: server.upsNames,
            descriptions: Array(server.upsDescriptions.values)
        )
        isRefusedByServer = server.deniedAccess
        if server.deniedAccess {
            step = .manual
            validationError = "\(server.displayName) is refusing connections from this Mac."
            return
        }
        if server.requiresAuthentication {
            showsAuthentication = true
            step = .manual
            validationError = "This server needs a username and password."
            return
        }
        await enumerateServer()
    }

    // MARK: - Enumerating the server

    /// Connects, proves the server speaks NUT, and lists the UPS devices it
    /// serves together with a live reading for each.
    func enumerateServer() async {
        guard let configuration = currentConfiguration() else { return }
        isValidating = true
        validationError = nil
        isRefusedByServer = false
        defer { isValidating = false }

        // A typed address has no host name yet; look it up off the main
        // thread, as it can take a moment on a network with no reverse DNS.
        if serverHostName == nil {
            let address = configuration.host
            serverHostName = await Task.detached { NUTDiscovery.reverseDNSName(for: address) }.value
        }

        let client = NUTClient(configuration: configuration)
        do {
            try await client.connect()
            let devices = try await client.listUPS()
            guard !devices.isEmpty else {
                await client.disconnect()
                validationError = "That server is running NUT, but it isn't serving any UPS devices."
                step = recoveryStep
                return
            }

            var found: [UPSCandidate] = []
            for device in devices {
                let reading = try? await client.reading(ups: device.name)
                found.append(
                    UPSCandidate(
                        name: device.name,
                        serverDescription: device.description == "Unavailable" ? nil : device.description,
                        reading: reading
                    )
                )
            }
            await client.disconnect()

            serverKind = NUTServerKind.detect(
                hostName: serverHostName,
                upsNames: found.map(\.name),
                descriptions: found.compactMap(\.serverDescription),
                manufacturers: found.compactMap { $0.reading.flatMap(UPSNaming.manufacturer(in:)) }
            ) ?? serverKind
            candidates = found
            selectedUPSName = found.first?.name
            step = .select
        } catch {
            await client.disconnect()
            handleEnumerationFailure(error)
        }
    }

    private func handleEnumerationFailure(_ error: Error) {
        let nutError = error as? NUTError
        validationError = nutError?.friendlyDescription ?? error.localizedDescription
        switch nutError {
        case .accessDenied:
            // Refused by address, not by password.
            isRefusedByServer = true
        case .connectionFailed(let reason) where reason.contains("closed") || reason.contains("refused"):
            // Some servers drop a client that is not on their list rather
            // than answering it, which looks exactly like this.
            isRefusedByServer = true
        case let error? where error.isAuthenticationProblem:
            // A sign-in has to be typed, which only the manual form can take.
            showsAuthentication = true
            step = .manual
            return
        default:
            break
        }
        step = recoveryStep
    }

    /// Where an error that needs no typing sends people: back to the search
    /// results if that's where the server came from, where the notice shows.
    private var recoveryStep: Step {
        isEditing ? .manual : serverSource
    }

    /// The configuration the fields currently describe, or nil with the reason
    /// already placed in `validationError`.
    private func currentConfiguration() -> NUTClient.Configuration? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            validationError = "Enter the address of your NUT server."
            return nil
        }
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)), portNumber > 0 else {
            validationError = "The port must be a number between 1 and 65535."
            return nil
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return NUTClient.Configuration(
            host: trimmedHost,
            port: portNumber,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            password: password.isEmpty ? nil : password
        )
    }

    // MARK: - Connecting

    /// Runs the real connection sequence, one visible stage per real operation.
    func connect() async {
        guard let candidate = selectedCandidate, let configuration = currentConfiguration() else { return }

        step = .connecting
        outcome = nil
        capturedReading = nil
        stages = ConnectionStage.Kind.allCases.map { ConnectionStage(kind: $0) }

        // 1. Is the server there, and is it really speaking NUT?
        mark(.reachServer, .running)
        let probe = NUTClient(
            configuration: .init(host: configuration.host, port: configuration.port, timeout: configuration.timeout)
        )
        do {
            try await probe.connect()
            _ = try? await probe.protocolVersion()
            await probe.disconnect()
            mark(.reachServer, .succeeded)
        } catch let error as NUTError where error.isAuthenticationProblem {
            // It answered in NUT; it just will not talk to strangers.
            await probe.disconnect()
            mark(.reachServer, .succeeded)
        } catch {
            await probe.disconnect()
            finish(failing: .reachServer, with: error)
            return
        }

        // 2. Credentials, if this server wants any.
        let client = NUTClient(configuration: configuration)
        let usesCredentials = configuration.username != nil || configuration.password != nil
        mark(.authenticate, usesCredentials ? .running : .skipped("Not required by this server"))
        do {
            try await client.connect()
            if usesCredentials { mark(.authenticate, .succeeded) }
        } catch {
            await client.disconnect()
            finish(failing: usesCredentials ? .authenticate : .reachServer, with: error)
            return
        }

        // 3. A real reading, before anything is written down.
        mark(.readUPS, .running)
        let reading: UPSReading
        do {
            reading = try await client.reading(ups: candidate.name)
            capturedReading = reading
            mark(.readUPS, .succeeded)
        } catch {
            await client.disconnect()
            finish(failing: .readUPS, with: error)
            return
        }
        await client.disconnect()

        // 4. Save it and hand it to macOS.
        let device = makeDevice(for: candidate, configuration: configuration, reading: reading)
        persist(device, password: configuration.password)
        connectedDevice = device

        mark(.publish, .running)
        guard settings.preferences.publishPowerSource else {
            mark(.publish, .skipped("Turned off in Settings"))
            mark(.verify, .skipped("Turned off in Settings"))
            outcome = .connectedOnly(
                "Squirrel is reading this UPS, but presenting it to macOS is turned off in Squirrel's settings."
            )
            step = .finished
            return
        }
        guard publisher.isSupported else {
            mark(.publish, .failed("This version of macOS isn't accepting a UPS from Squirrel."))
            mark(.verify, .skipped("Nothing to check"))
            outcome = .connectedOnly(
                "Squirrel is reading this UPS, but this version of macOS isn't accepting a published power source. Squirrel will keep monitoring, and your Mac's own UPS shutdown settings won't apply."
            )
            step = .finished
            return
        }

        if monitor.isPaused { monitor.resume() }
        monitor.restart()

        guard await waitUntil(timeout: publishTimeout, condition: { await self.publisher.isPublishing }) else {
            mark(.publish, .failed("macOS did not accept the power source."))
            mark(.verify, .skipped("Nothing to check"))
            outcome = .connectedOnly(
                "Squirrel is reading this UPS, but macOS did not accept it as a power source. Your Mac's UPS shutdown settings won't apply yet."
            )
            step = .finished
            return
        }
        mark(.publish, .succeeded)

        // 5. Ask macOS what it can see, rather than claiming it worked.
        mark(.verify, .running)
        let name = device.displayName
        guard await waitUntil(timeout: verifyTimeout, condition: { SystemPowerSources.isPublishedUPSVisible(named: name) }) else {
            mark(.verify, .failed("macOS isn't reporting the UPS yet."))
            outcome = .connectedOnly(
                "Squirrel published the UPS, but macOS isn't reporting it yet. Squirrel keeps trying in the background; if it doesn't appear, check that no other UPS software is running."
            )
            step = .finished
            return
        }
        mark(.verify, .succeeded)
        outcome = .published
        step = .finished
        log.notice("Assistant finished: macOS is reporting \(name, privacy: .public)")
    }

    /// Lets the user try again without starting over.
    func retryConnection() async {
        await connect()
    }

    /// Whether sharing with macOS is switched off in Squirrel's settings,
    /// the one connected-only result that trying again can't change.
    var isSharingOff: Bool { !settings.preferences.publishPowerSource }

    /// Turns sharing with macOS on, the same switch as Settings ▸ Power, and
    /// runs the connection again so the result says whether macOS sees it.
    func shareWithMacOS() async {
        settings.preferences.publishPowerSource = true
        await connect()
    }

    func returnToSelection() {
        outcome = nil
        stages = []
        step = candidates.isEmpty ? recoveryStep : .select
    }

    // MARK: - Saving

    private func makeDevice(
        for candidate: UPSCandidate,
        configuration: NUTClient.Configuration,
        reading: UPSReading
    ) -> UPSDevice {
        // Reconnecting a UPS that is already configured updates it rather
        // than adding a second copy — two entries polling one server is a
        // configuration that can only fight with itself.
        let existing = editingDeviceID.flatMap { settings.device(id: $0) }
            ?? settings.devices.first {
                $0.host == configuration.host && $0.port == configuration.port && $0.upsName == candidate.name
            }
        var device = UPSDevice(
            id: existing?.id ?? UUID(),
            // A name the user gave it is theirs: reconnecting must not
            // overwrite it with whatever the driver calls the model.
            displayName: chosenName(for: candidate, existing: existing, reading: reading),
            host: configuration.host,
            port: configuration.port,
            upsName: candidate.name,
            username: configuration.username,
            publishesToSystem: existing?.publishesToSystem ?? (settings.systemDevice == nil),
            pollInterval: existing?.pollInterval ?? 5
        )
        // Likewise a picture the user chose by hand.
        device.illustrationOverride = existing?.illustrationOverride
        return device
    }

    private func chosenName(for candidate: UPSCandidate, existing: UPSDevice?, reading: UPSReading) -> String {
        let typed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return existing?.displayName ?? UPSNaming.suggestedName(for: reading) ?? candidate.title
    }

    private func persist(_ device: UPSDevice, password: String?) {
        // An edit can move the UPS to another server, which changes the
        // Keychain account; drop the old entry rather than orphaning it.
        if let existing = settings.device(id: device.id),
           existing.keychainAccount != device.keychainAccount {
            settings.credentialStore.setPassword(nil, forAccount: existing.keychainAccount)
        }
        settings.credentialStore.setPassword(password, forAccount: device.keychainAccount)
        settings.upsert(device)
    }

    // MARK: - Stage plumbing

    private func mark(_ kind: ConnectionStage.Kind, _ status: ConnectionStage.Status) {
        guard let index = stages.firstIndex(where: { $0.kind == kind }) else { return }
        stages[index].status = status
    }

    private func finish(failing kind: ConnectionStage.Kind, with error: Error) {
        let message = (error as? NUTError)?.friendlyDescription ?? error.localizedDescription
        mark(kind, .failed(message))
        for stage in stages where stage.status == .pending {
            mark(stage.kind, .skipped("Not reached"))
        }
        outcome = .failed(message)
        step = .finished
        log.error("Assistant failed at \(String(describing: kind), privacy: .public): \(message, privacy: .public)")
    }

    /// Polls a real condition until it holds or the deadline passes. The UI
    /// never advances on a timer alone.
    private func waitUntil(timeout: TimeInterval, condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return await condition()
    }
}
