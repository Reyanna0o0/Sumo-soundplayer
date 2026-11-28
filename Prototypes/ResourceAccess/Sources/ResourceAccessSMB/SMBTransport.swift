import Foundation
import ResourceAccessCore

/// Codable source records contain only SourceConnection's opaque credential reference.
/// This derived configuration intentionally has no credential fields.
public struct SMBConnectionConfiguration: Sendable, Equatable {
    public let serverURL: URL
    public let host: String
    public let port: Int
    public let share: String
    public let rootPath: ResourcePath
    public let requiresEncryption: Bool

    public init(connection: SourceConnection, requiresEncryption: Bool = false) throws {
        guard connection.kind == .smb,
              let parts = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              (1...65535).contains(parts.port ?? 445) else {
            throw ResourceAccessError.invalidConfiguration("Expected an SMB server and share")
        }
        // Decode each URL component once. An encoded separator must never change its boundary.
        let encoded = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let components = try encoded.map { component -> String in
            guard let decoded = String(component).removingPercentEncoding else {
                throw ResourceAccessError.invalidConfiguration("Invalid SMB source encoding")
            }
            try Self.validateComponent(decoded)
            return decoded
        }
        guard let share = components.first else {
            throw ResourceAccessError.invalidConfiguration("An SMB share is required")
        }
        var server = URLComponents()
        server.scheme = "smb"; server.host = host; server.port = parts.port
        guard let serverURL = server.url else {
            throw ResourceAccessError.invalidConfiguration("Invalid SMB host")
        }
        self.serverURL = serverURL; self.host = host; self.port = parts.port ?? 445
        self.share = share; self.rootPath = try ResourcePath(components.dropFirst().joined(separator: "/"))
        self.requiresEncryption = requiresEncryption
    }

    public func shareRelativePath(for path: ResourcePath) throws -> ResourcePath {
        try path.components.forEach(Self.validateComponent)
        return try ResourcePath((rootPath.components + path.components).joined(separator: "/"))
    }

    /// Conservative Windows-compatible components; disallow ADS and wildcard syntax too.
    public static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)) == nil,
              !value.hasSuffix("."), !value.hasSuffix(" ") else {
            throw ResourceAccessError.invalidPath("Invalid SMB path component")
        }
    }
}

public enum SMBItemKind: Sendable, Equatable { case regularFile, directory, symbolicLink, other }

public struct SMBFileInfo: Sendable, Equatable {
    public let kind: SMBItemKind
    public let size: Int64?
    public let modifiedAt: Date?
    /// Optional verified content hash, never manufactured from size/mtime.
    public let contentHash: String?
    public init(kind: SMBItemKind, size: Int64? = nil, modifiedAt: Date? = nil, contentHash: String? = nil) {
        self.kind = kind; self.size = size; self.modifiedAt = modifiedAt; self.contentHash = contentHash
    }
}

public struct SMBDirectoryItem: Sendable, Equatable {
    /// A single raw filename, not a URL or a path provided by the server.
    public let name: String
    public let info: SMBFileInfo
    public init(name: String, info: SMBFileInfo) { self.name = name; self.info = info }
}

/// Ephemeral operation context. Do not persist it or the underlying SDK manager.
public struct SMBRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let configuration: SMBConnectionConfiguration
    public let path: ResourcePath
    public let credential: ResourceCredential?
    public init(configuration: SMBConnectionConfiguration, path: ResourcePath, credential: ResourceCredential?) {
        self.configuration = configuration; self.path = path; self.credential = credential
    }
    public var description: String { "SMBRequest(credentials: <redacted>)" }
    public var debugDescription: String { description }
}

public enum SMBTransportError: Error, Sendable, Equatable {
    case authenticationRequired, permissionDenied, notFound, unavailable, timedOut, cancelled
    case unsupported, invalidResponse, resourceChanged
}

/// SMB2/3 backend boundary. Operations must honor bounded reads and task cancellation.
/// A real backend must disclose whether a blocked network call can only cancel at its timeout.
public protocol SMBTransport: Sendable {
    func stat(_ request: SMBRequest) async throws -> SMBFileInfo
    func listChildren(_ request: SMBRequest) async throws -> [SMBDirectoryItem]
    func read(_ request: SMBRequest, range: ByteRange) async throws -> Data
}

public func classifySMBError(_ error: Error) -> ResourceAccessError {
    if error is CancellationError { return .cancelled }
    if let error = error as? ResourceAccessError { return error }
    if let error = error as? SMBTransportError {
        switch error {
        case .authenticationRequired: return .authorizationRequired
        case .permissionDenied: return .permissionDenied
        case .notFound: return .notFound
        case .unavailable: return .temporarilyUnavailable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .unsupported: return .unsupported("SMB operation is unsupported")
        case .invalidResponse: return .invalidResponse("Invalid SMB response")
        case .resourceChanged: return .resourceChanged
        }
    }
    // Never pass arbitrary SDK descriptions through: they can include server/user details.
    return .invalidResponse("Unclassified SMB operation failure")
}
