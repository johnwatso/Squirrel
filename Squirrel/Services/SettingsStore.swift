import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var devices: [UPSDevice] { didSet { save(devices, forKey: Keys.devices) } }
    @Published var preferences: AppPreferences { didSet { save(preferences, forKey: Keys.preferences) } }

    private enum Keys {
        static let devices = "configuredUPSDevices"
        static let removedHistoryIDs = "removedUPSHistoryIDs"
        static let preferences = "preferences"
    }

    private var removedHistoryIDs: [String: UUID]
    private let defaults: UserDefaults
    let credentialStore: any CredentialStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, credentialStore: any CredentialStoring = KeychainCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.removedHistoryIDs = Self.load([String: UUID].self, forKey: Keys.removedHistoryIDs, from: defaults) ?? [:]
        self.devices = Self.load([UPSDevice].self, forKey: Keys.devices, from: defaults) ?? []
        self.preferences = Self.load(AppPreferences.self, forKey: Keys.preferences, from: defaults) ?? AppPreferences()
        if let first = self.devices.first(where: { $0.publishesToSystem })?.id {
            self.devices = self.devices.map { device in
                var updated = device
                updated.publishesToSystem = device.id == first
                return updated
            }
        }
    }

    /// The one UPS presented to macOS. The Mac has a single set of shutdown
    /// thresholds, so only one device can own them.
    var systemDevice: UPSDevice? {
        devices.first { $0.publishesToSystem }
    }

    func device(id: UUID) -> UPSDevice? { devices.first { $0.id == id } }

    /// History is keyed by device UUID. Reuse the archived UUID when the
    /// setup assistant adds the same NUT endpoint again.
    func historyIDForNewDevice(host: String, port: UInt16, upsName: String) -> UUID {
        let key = Self.historyKey(host: host, port: port, upsName: upsName)
        guard let id = removedHistoryIDs[key], device(id: id) == nil else { return UUID() }
        return id
    }

    private static func historyKey(host: String, port: UInt16, upsName: String) -> String {
        "\(host.lowercased()):\(port)/\(upsName)"
    }

    func upsert(_ device: UPSDevice) {
        var updated = devices.map { existing in
            var entry = existing
            if device.publishesToSystem, entry.id != device.id { entry.publishesToSystem = false }
            return entry
        }
        if let index = updated.firstIndex(where: { $0.id == device.id }) {
            updated[index] = device
        } else {
            updated.append(device)
        }
        devices = updated
        let key = Self.historyKey(host: device.host, port: device.port, upsName: device.upsName)
        if removedHistoryIDs[key] == device.id {
            removedHistoryIDs[key] = nil
            save(removedHistoryIDs, forKey: Keys.removedHistoryIDs)
        }
    }

    func setProtectionDevice(_ id: UUID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        devices = devices.map { device in
            var updated = device
            updated.publishesToSystem = device.id == id
            return updated
        }
    }

    func remove(id: UUID) {
        if let device = device(id: id) {
            let key = Self.historyKey(host: device.host, port: device.port, upsName: device.upsName)
            removedHistoryIDs[key] = device.id
            save(removedHistoryIDs, forKey: Keys.removedHistoryIDs)
            credentialStore.setPassword(nil, forAccount: device.keychainAccount)
        }
        devices.removeAll { $0.id == id }
    }

    func password(for device: UPSDevice) -> String? {
        credentialStore.password(forAccount: device.keychainAccount)
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
