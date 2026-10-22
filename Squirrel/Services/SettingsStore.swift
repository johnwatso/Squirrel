import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var devices: [UPSDevice] { didSet { save(devices, forKey: Keys.devices) } }
    @Published var preferences: AppPreferences { didSet { save(preferences, forKey: Keys.preferences) } }

    private enum Keys {
        static let devices = "configuredUPSDevices"
        static let preferences = "preferences"
    }

    private let defaults: UserDefaults
    let credentialStore: any CredentialStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, credentialStore: any CredentialStoring = KeychainCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.devices = Self.load([UPSDevice].self, forKey: Keys.devices, from: defaults) ?? []
        self.preferences = Self.load(AppPreferences.self, forKey: Keys.preferences, from: defaults) ?? AppPreferences()
    }

    /// The one UPS presented to macOS. The Mac has a single set of shutdown
    /// thresholds, so only one device can own them.
    var systemDevice: UPSDevice? {
        devices.first { $0.publishesToSystem }
    }

    func device(id: UUID) -> UPSDevice? { devices.first { $0.id == id } }

    func upsert(_ device: UPSDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    func remove(id: UUID) {
        if let device = device(id: id) {
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
