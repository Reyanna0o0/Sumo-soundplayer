#if canImport(Security)
import Foundation
import Security

/// Only secret storage uses an encoded envelope; SourceConnection encodes the
/// opaque reference. No credentials are included in logs or catalog JSON.
public struct KeychainCredentialStore: CredentialProvider, Sendable {
    private let service: String
    public init(service: String = "com.sumo.resource-access.credentials") { self.service = service }
    private struct Envelope: Codable {
        let kind: String
        let username: String?
        let password: String?
        let domain: String?
        let token: String?
    }
    public func credential(for reference: CredentialReference) async throws -> ResourceCredential? {
        var query = base(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ResourceAccessError.authorizationRequired }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if envelope.kind == "password", let username = envelope.username, let password = envelope.password {
            return .usernamePassword(username: username, password: password, domain: envelope.domain)
        }
        if envelope.kind == "bearer", let token = envelope.token { return .bearer(token) }
        throw ResourceAccessError.authorizationRequired
    }
    public func set(_ credential: ResourceCredential?, for reference: CredentialReference) async throws {
        let query = base(reference)
        guard let credential else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ResourceAccessError.permissionDenied }
            return
        }
        let envelope: Envelope
        switch credential {
        case .usernamePassword(let user, let password, let domain): envelope = .init(kind: "password", username: user, password: password, domain: domain, token: nil)
        case .bearer(let token): envelope = .init(kind: "bearer", username: nil, password: nil, domain: nil, token: token)
        }
        let data = try JSONEncoder().encode(envelope)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ResourceAccessError.permissionDenied }
    }
    private func base(_ reference: CredentialReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: reference.id]
    }
}
#endif
