import Foundation
import Security

/// The session token, and nothing else.
///
/// Keychain rather than UserDefaults because the token is a bearer credential:
/// it is the whole of the user's authority over their account, and UserDefaults
/// is a plist in the app container that ends up in unencrypted backups.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the right class for a
/// background-refresh app -- the scheduler needs the token while the phone is
/// locked, and "ThisDeviceOnly" keeps it out of an iCloud backup restored onto
/// someone else's hardware.
///
/// Deliberately not a general-purpose keychain wrapper. One key, four
/// operations, so there is no surface for a mistake to hide in.
enum Keychain {
    private static let service = "com.cyan0914.hearth"
    private static let account = "session_token"

    static func saveSessionToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Delete-then-add, because SecItemAdd on an existing item is
        // errSecDuplicateItem rather than an update, and the update path
        // (SecItemUpdate) needs its own query. Two calls is fewer branches than
        // handling both.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            // Not thrown: the app still works for this launch, the user just
            // signs in again next time. Logged without the token.
            print("[Hearth] keychain write failed: \(status)")
        }
    }

    static func sessionToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func clearSessionToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
