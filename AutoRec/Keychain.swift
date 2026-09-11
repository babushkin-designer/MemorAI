import Foundation
import Security

/// Read-only access to generic passwords in the login Keychain.
/// API keys live there as global items (service = "bluesminds-api-key" /
/// "openai-api-key" / "deepgram-api-key", account = current user) so every project on this machine
/// shares one copy. First read from the app may show a Keychain permission
/// prompt — answer "Always Allow".
enum Keychain {
    static func read(service: String, account: String = NSUserName()) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                log("[Keychain] Read failed for \(service): OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
