import Foundation

public enum ResourceAccessError: Error, Equatable, Sendable {
    case invalidConfiguration(String), invalidPath(String)
    case authorizationRequired, permissionDenied, notFound
    case temporarilyUnavailable, timedOut, cancelled
    case unsupported(String), invalidResponse(String), resourceChanged, limitExceeded
}

public struct TrackIdentity: Hashable, Codable, Sendable {
    public let workID: Int64
    public let trackID: Int64
    public init(workID: Int64, trackID: Int64) { self.workID = workID; self.trackID = trackID }
}

/// An opaque key only. Credentials must never be encoded into a source record.
public struct CredentialReference: Hashable, Codable, Sendable {
    public let id: String
    public init(_ id: String = UUID().uuidString) { self.id = id }
}

public enum ResourceCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case usernamePassword(username: String, password: String, domain: String? = nil)
    case bearer(String)
    public var description: String { "ResourceCredential(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol CredentialProvider: Sendable {
    func credential(for reference: CredentialReference) async throws -> ResourceCredential?
}

public actor InMemoryCredentialStore: CredentialProvider {
    private var values: [CredentialReference: ResourceCredential] = [:]
    public init() {}
    public func set(_ credential: ResourceCredential?, for reference: CredentialReference) { values[reference] = credential }
    public func credential(for reference: CredentialReference) -> ResourceCredential? { values[reference] }
}

public enum SourceKind: String, Codable, Sendable { case http, webDAV, smb, ownedLocal, systemDocument }

public struct SourceConnection: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: SourceKind
    /// HTTP/WebDAV: chosen directory root; SMB: smb://host/share/chosen-root.
    public let endpoint: URL
    public let credentialReference: CredentialReference?
    public let allowsInsecureHTTP: Bool
    public init(id: UUID = UUID(), kind: SourceKind, endpoint: URL,
                credentialReference: CredentialReference? = nil, allowsInsecureHTTP: Bool = false) throws {
        guard endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.query == nil else { throw ResourceAccessError.invalidConfiguration("Credentials/query/fragment are not source-root fields") }
        switch kind {
        case .http, .webDAV:
            guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
                  endpoint.host?.isEmpty == false else { throw ResourceAccessError.invalidConfiguration("Expected an HTTP(S) directory root") }
            if endpoint.scheme?.lowercased() == "http" && !allowsInsecureHTTP {
                throw ResourceAccessError.invalidConfiguration("Plain HTTP requires explicit opt-in")
            }
        case .smb:
            guard endpoint.scheme?.lowercased() == "smb", endpoint.host?.isEmpty == false,
                  !endpoint.path.split(separator: "/").isEmpty else { throw ResourceAccessError.invalidConfiguration("Expected smb://host/share[/selected-root]") }
        case .ownedLocal, .systemDocument:
            guard endpoint.isFileURL else { throw ResourceAccessError.invalidConfiguration("Expected a file URL") }
        }
        let components = endpoint.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0") }) else {
            throw ResourceAccessError.invalidConfiguration("Invalid source root")
        }
        self.id = id; self.kind = kind; self.endpoint = endpoint
        self.credentialReference = credentialReference; self.allowsInsecureHTTP = allowsInsecureHTTP
    }
    private enum CodingKeys: String, CodingKey { case id, kind, endpoint, credentialReference, allowsInsecureHTTP }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), kind: c.decode(SourceKind.self, forKey: .kind),
                      endpoint: c.decode(URL.self, forKey: .endpoint), credentialReference: c.decodeIfPresent(CredentialReference.self, forKey: .credentialReference),
                      allowsInsecureHTTP: c.decodeIfPresent(Bool.self, forKey: .allowsInsecureHTTP) ?? false)
    }
}

/// Raw, unescaped components relative to a user-selected root. Never an absolute URL.
public struct ResourcePath: Hashable, Codable, Sendable {
    public let components: [String]
    public var string: String { components.joined(separator: "/") }
    public static let root = try! ResourcePath("")
    public init(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw ResourceAccessError.invalidPath("Absolute or invalid path") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ResourceAccessError.invalidPath("Invalid relative component") }
        components = path.isEmpty ? [] : parts
    }
    public func appending(_ name: String) throws -> ResourcePath {
        guard !name.contains("/") else { throw ResourceAccessError.invalidPath("Expected a single component") }
        return try ResourcePath((components + [name]).joined(separator: "/"))
    }
    public func url(relativeTo root: URL) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(string) }
}

public struct ByteRange: Equatable, Sendable {
    public static let maximumLength = 1_048_576
    public let offset: Int64
    public let length: Int
    public var lastOffset: Int64 { offset + Int64(length) - 1 }
    public init(offset: Int64, length: Int) throws {
        guard offset >= 0, length > 0, length <= Self.maximumLength,
              offset <= Int64.max - Int64(length) else { throw ResourceAccessError.invalidConfiguration("Invalid or oversized byte range") }
        self.offset = offset; self.length = length
    }
}

public enum RevisionMatch: String, Sendable { case same, different, unknown }
public struct ResourceRevision: Codable, Equatable, Sendable {
    public let size: Int64?
    public let etag: String?
    public let modifiedAt: Date?
    /// SHA-256 of the complete file, as 64 hexadecimal characters. Never size/mtime.
    public let contentHash: String?
    public init(size: Int64? = nil, etag: String? = nil, modifiedAt: Date? = nil, contentHash: String? = nil) {
        self.size = size; self.etag = etag; self.modifiedAt = modifiedAt; self.contentHash = contentHash
    }
    public var strongETag: String? { guard let etag, etag.hasPrefix("\""), etag.hasSuffix("\""), etag.count >= 2 else { return nil }; return etag }
    /// For the SAME resource: equality can be established by content hashes or strong ETags.
    /// Size/mtime alone can reject a change, but cannot prove byte-for-byte identity.
    public func match(_ other: Self) -> RevisionMatch {
        if let a = size, let b = other.size, a != b { return .different }
        if let a = contentHash, let b = other.contentHash { return a == b ? .same : .different }
        if let a = strongETag, let b = other.strongETag { return a == b ? .same : .different }
        if let a = modifiedAt, let b = other.modifiedAt, a != b { return .different }
        if let a = etag, let b = other.etag, a != b { return .different }
        return .unknown
    }
    /// ETags are scoped to a resource, not globally unique across NAS/path changes.
    public func contentMatchAcrossLocations(_ other: Self) -> RevisionMatch {
        if let a = size, let b = other.size, a != b { return .different }
        if let a = contentHash, let b = other.contentHash { return a == b ? .same : .different }
        return .unknown
    }
}

public struct ResourceMetadata: Equatable, Sendable {
    public let size: Int64?
    public let mimeType: String?
    public let isDirectory: Bool
    public let revision: ResourceRevision
    public init(size: Int64? = nil, mimeType: String? = nil, isDirectory: Bool = false, revision: ResourceRevision = .init()) {
        self.size = size; self.mimeType = mimeType; self.isDirectory = isDirectory; self.revision = revision
    }
}
public struct ResourceEntry: Equatable, Sendable {
    public let path: ResourcePath
    public let metadata: ResourceMetadata
    public init(path: ResourcePath, metadata: ResourceMetadata) { self.path = path; self.metadata = metadata }
}
public struct ResourceChunk: Sendable {
    public let data: Data
    public let offset: Int64
    public let totalLength: Int64?
    public let revision: ResourceRevision
    public init(data: Data, offset: Int64, totalLength: Int64? = nil, revision: ResourceRevision = .init()) {
        self.data = data; self.offset = offset; self.totalLength = totalLength; self.revision = revision
    }
}

public enum CapabilitySupport: String, Codable, Sendable { case supported, unsupported, unknown }
public struct ResourceCapabilities: Equatable, Sendable {
    public var sequentialRead: CapabilitySupport
    public var randomAccess: CapabilitySupport
    public var completeDownload: CapabilitySupport
    public var resumableDownload: CapabilitySupport
    public var directPlayback: CapabilitySupport
    public var accurateMediaSeek: CapabilitySupport
    public var verifiedAt: Date?
    public init(sequentialRead: CapabilitySupport = .unknown, randomAccess: CapabilitySupport = .unknown,
                completeDownload: CapabilitySupport = .unknown, resumableDownload: CapabilitySupport = .unknown,
                directPlayback: CapabilitySupport = .unknown, accurateMediaSeek: CapabilitySupport = .unknown,
                verifiedAt: Date? = nil) {
        self.sequentialRead = sequentialRead; self.randomAccess = randomAccess
        self.completeDownload = completeDownload; self.resumableDownload = resumableDownload
        self.directPlayback = directPlayback; self.accurateMediaSeek = accurateMediaSeek; self.verifiedAt = verifiedAt
    }
}
public enum ResourceResidency: String, Sendable { case applicationOwnedComplete, externalManaged, remote, unknown }
public enum ResourceAvailability: Equatable, Sendable {
    case ready, preparing, requiresAuthorization, temporarilyUnavailable, missing, unknown
}
public enum PlaybackAccess: Equatable, Sendable {
    case localFile(URL)
    case httpURL(URL)
    /// A bridge is required; this is NOT a URL that AVPlayer can open directly.
    case byteReader(sourceID: UUID, path: ResourcePath)
    case requiresPreparation
    case unavailable
}
public struct ResourceProbe: Sendable {
    public let metadata: ResourceMetadata
    public let residency: ResourceResidency
    public let availability: ResourceAvailability
    public let capabilities: ResourceCapabilities
    public let playbackAccess: PlaybackAccess
    public init(metadata: ResourceMetadata, residency: ResourceResidency, availability: ResourceAvailability = .ready,
                capabilities: ResourceCapabilities, playbackAccess: PlaybackAccess) {
        self.metadata = metadata; self.residency = residency; self.availability = availability
        self.capabilities = capabilities; self.playbackAccess = playbackAccess
    }
}
public struct ResourceLocation: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let path: ResourcePath
    public let expectedRevision: ResourceRevision?
    public init(sourceID: UUID, path: ResourcePath, expectedRevision: ResourceRevision? = nil) {
        self.sourceID = sourceID; self.path = path; self.expectedRevision = expectedRevision
    }
}
public protocol ResourceLease: Sendable { func release() async }
public struct ResolvedResource: Sendable {
    public let identity: TrackIdentity
    public let location: ResourceLocation
    public let probe: ResourceProbe
    public let lease: (any ResourceLease)?
    public init(identity: TrackIdentity, location: ResourceLocation, probe: ResourceProbe, lease: (any ResourceLease)? = nil) {
        self.identity = identity; self.location = location; self.probe = probe; self.lease = lease
    }
}
public protocol ResourceResolver: Sendable {
    func resolve(_ identity: TrackIdentity, expectedRevision: ResourceRevision?) async throws -> ResolvedResource
}
public protocol ResourceAdapter: Sendable {
    var connection: SourceConnection { get }
    func metadata(at path: ResourcePath) async throws -> ResourceMetadata
    /// Nonrecursive, immediate children only, within the explicitly selected root.
    func listChildren(at path: ResourcePath) async throws -> [ResourceEntry]
    func read(at path: ResourcePath, range: ByteRange, expectedRevision: ResourceRevision?) async throws -> ResourceChunk
    func probe(at path: ResourcePath) async throws -> ResourceProbe
}
