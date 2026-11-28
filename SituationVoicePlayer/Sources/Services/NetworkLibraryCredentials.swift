import Foundation
import Security
import ResourceAccessCore

/// Passwords live in this app's Keychain, never in the catalogue or backup JSON.
final class NetworkLibraryCredentials: CredentialProvider, @unchecked Sendable {
    private let service = "io.github.gloriaguuuu.simo.network-sources.v1"
    private struct Stored: Codable { let username: String; let password: String; let domain: String? }

    func credential(for reference: CredentialReference) async throws -> ResourceCredential? {
        try read(reference)
    }

    func read(_ reference: CredentialReference) throws -> ResourceCredential? {
        var query = key(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ResourceAccessError.authorizationRequired
        }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        return .usernamePassword(username: stored.username, password: stored.password, domain: stored.domain)
    }

    func set(_ credential: ResourceCredential?, for reference: CredentialReference) throws {
        guard let credential else {
            let status = SecItemDelete(key(reference) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ResourceAccessError.authorizationRequired
            }
            return
        }
        guard case let .usernamePassword(username, password, domain) = credential else {
            throw ResourceAccessError.unsupported("Credential type")
        }
        let data = try JSONEncoder().encode(Stored(username: username, password: password, domain: domain))
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key(reference) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = key(reference)
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ResourceAccessError.authorizationRequired
            }
        } else if status != errSecSuccess { throw ResourceAccessError.authorizationRequired }
    }

    private func key(_ reference: CredentialReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: reference.id]
    }
}
