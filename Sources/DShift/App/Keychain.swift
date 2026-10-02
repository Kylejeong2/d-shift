import Foundation
import Security

/// Generic-password storage in the login keychain, used for the API key in the downloadable app.
enum Keychain {
    private static let service = "com.kylejeong2.dshift"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Whether an API key is configured, so the sidebar can show setup instead of a chat that would fail.
@MainActor
final class APIKeyStore: ObservableObject {
    static let shared = APIKeyStore()
    private static let account = "ANTHROPIC_API_KEY"

    @Published private(set) var hasKey = Config.value(account) != nil

    func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.save(trimmed, for: Self.account) else { return false }
        hasKey = true
        return true
    }

    /// Forgets the keychain key. A key from the environment or a .env file still applies.
    func reset() {
        Keychain.delete(Self.account)
        hasKey = Config.value(Self.account) != nil
    }
}
