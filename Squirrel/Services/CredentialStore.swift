import Foundation
import Security

protocol CredentialStoring: Sendable {
    func password(forAccount account: String) -> String?
    func setPassword(_ password: String?, forAccount account: String)
}

/// NUT passwords live in the login Keychain, never in preferences.
struct KeychainCredentialStore: CredentialStoring {
    private let service = "io.github.johnwatso.Squirrel"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func password(forAccount account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String?, forAccount account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
