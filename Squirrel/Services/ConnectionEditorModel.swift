import Foundation
import SquirrelCore

/// A draft for an existing UPS. Probing never changes saved settings or the
/// monitor; only saving a successfully tested draft applies it.
@MainActor
final class ConnectionEditorModel: ObservableObject, Identifiable {
    typealias Probe = (NUTClient.Configuration) async throws -> [UPSCandidate]

    let id = UUID()
    let device: UPSDevice
    @Published var host: String { didSet { invalidateTest() } }
    @Published var port: String { didSet { invalidateTest() } }
    @Published var username: String { didSet { invalidateTest() } }
    @Published var password: String { didSet { invalidateTest() } }
    @Published var showsAuthentication: Bool
    @Published var selectedUPSName: String?
    @Published private(set) var candidates: [UPSCandidate] = []
    @Published private(set) var isTesting = false
    @Published private(set) var error: String?
    @Published private(set) var hasTested = false

    private let settings: SettingsStore
    private let probe: Probe
    private let onSave: () -> Void
    private let originalPassword: String
    private var testedConfiguration: NUTClient.Configuration?
    private var revision = 0
    private var isCancelled = false

    init(device: UPSDevice, settings: SettingsStore, probe: Probe? = nil, onSave: @escaping () -> Void = {}) {
        self.device = device
        self.settings = settings
        self.probe = probe ?? Self.probeServer
        self.onSave = onSave
        let password = settings.password(for: device) ?? ""
        originalPassword = password
        host = device.host
        port = String(device.port)
        username = device.username ?? ""
        self.password = password
        showsAuthentication = device.username?.isEmpty == false || !password.isEmpty
        selectedUPSName = device.upsName
    }

    var configuration: NUTClient.Configuration? {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              let number = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else { return nil }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(host: address, port: number, username: user.isEmpty ? nil : user, password: password.isEmpty ? nil : password)
    }

    var selectedCandidate: UPSCandidate? { candidates.first { $0.name == selectedUPSName } }

    var hasChanges: Bool {
        guard let configuration else { return true }
        return configuration.host != device.host || configuration.port != device.port
            || configuration.username != device.username || (configuration.password ?? "") != originalPassword
            || selectedUPSName != device.upsName
    }

    var canSave: Bool {
        !isCancelled && !isTesting && hasChanges && configuration != nil
            && testedConfiguration == configuration && selectedCandidate?.reading != nil
    }

    var resultMessage: String? {
        guard hasTested else { return nil }
        guard let candidate = selectedCandidate else { return "Choose a UPS from this server." }
        guard let reading = candidate.reading else { return "The server responded, but it could not provide a reading for this UPS. Check its connection and your credentials, then test again." }
        return "Connection verified · \(MenuBarPresentation.statusPhrase(for: reading.status))"
    }

    func testConnection() async {
        guard !isTesting, !isCancelled else { return }
        guard let configuration else {
            error = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter the address of your NUT server."
                : "Enter a port between 1 and 65535."
            return
        }
        isTesting = true
        error = nil
        hasTested = false
        testedConfiguration = nil
        let attempt = revision
        defer { isTesting = false }
        do {
            let found = try await probe(configuration)
            guard attempt == revision, !isCancelled, !Task.isCancelled else { return }
            guard !found.isEmpty else {
                error = "This server is not serving any UPS devices."
                candidates = []
                return
            }
            candidates = found
            // A sole device needs no picker. With multiple devices, retain the
            // configured target or require an explicit choice if it is absent.
            if found.count == 1 {
                selectedUPSName = found[0].name
            } else if !found.contains(where: { $0.name == selectedUPSName }) {
                selectedUPSName = nil
            }
            testedConfiguration = configuration
            hasTested = true
        } catch {
            guard attempt == revision, !isCancelled, !Task.isCancelled else { return }
            self.error = (error as? NUTError)?.friendlyDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    func save() -> Bool {
        guard canSave, let configuration, let upsName = selectedUPSName else { return false }
        guard var current = settings.device(id: device.id) else {
            error = "This UPS was removed. Close this window and select another UPS."
            return false
        }
        guard current.host == device.host, current.port == device.port,
              current.upsName == device.upsName, current.username == device.username,
              (settings.password(for: current) ?? "") == originalPassword else {
            error = "This connection changed while you were editing it. Close and reopen Connection to load the latest settings."
            return false
        }
        guard !settings.devices.contains(where: {
            $0.id != device.id && $0.host.caseInsensitiveCompare(configuration.host) == .orderedSame
                && $0.port == configuration.port && $0.upsName == upsName
        }) else {
            error = "That UPS is already configured in Squirrel. Choose it in the sidebar instead."
            return false
        }
        let oldAccount = current.keychainAccount
        current.host = configuration.host
        current.port = configuration.port
        current.upsName = upsName
        current.username = configuration.username
        settings.credentialStore.setPassword(configuration.password, forAccount: current.keychainAccount)
        settings.upsert(current)
        if oldAccount != current.keychainAccount,
           !settings.devices.contains(where: { $0.keychainAccount == oldAccount }) {
            settings.credentialStore.setPassword(nil, forAccount: oldAccount)
        }
        onSave()
        return true
    }

    func cancel() {
        isCancelled = true
        revision += 1
    }

    private func invalidateTest() {
        revision += 1
        testedConfiguration = nil
        hasTested = false
        error = nil
        candidates = []
        selectedUPSName = device.upsName
    }

    private static func probeServer(_ configuration: NUTClient.Configuration) async throws -> [UPSCandidate] {
        let client = NUTClient(configuration: configuration)
        // Bound the whole probe, including servers that accept TCP but never
        // answer. Aborting releases the client's pending network continuation.
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(configuration.timeout))
                await client.abort()
            } catch { }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await client.connect()
                let devices = try await client.listUPS()
                var found: [UPSCandidate] = []
                for device in devices {
                    try Task.checkCancellation()
                    let reading = try? await client.reading(ups: device.name)
                    found.append(.init(name: device.name, serverDescription: device.description, reading: reading))
                }
                try Task.checkCancellation()
                await client.abort()
                return found
            } catch {
                await client.abort()
                throw error
            }
        } onCancel: {
            Task { await client.abort() }
        }
    }
}
