import Foundation
import ResourceAccessCore

/// Read-only SMB resource adapter. A byte reader is not a directly playable smb:// URL.
public struct SMBResourceAdapter: ResourceAdapter {
    public let connection: SourceConnection
    public let configuration: SMBConnectionConfiguration
    private let credentials: any CredentialProvider
    private let transport: any SMBTransport

    public init(connection: SourceConnection, credentialProvider: any CredentialProvider,
                transport: any SMBTransport, requiresEncryption: Bool = false) throws {
        self.configuration = try SMBConnectionConfiguration(connection: connection, requiresEncryption: requiresEncryption)
        self.connection = connection; self.credentials = credentialProvider; self.transport = transport
    }

    private func request(for path: ResourcePath) async throws -> SMBRequest {
        try Task.checkCancellation()
        let resolved = try configuration.shareRelativePath(for: path)
        let credential: ResourceCredential?
        if let reference = connection.credentialReference {
            guard let stored = try await credentials.credential(for: reference) else {
                throw ResourceAccessError.authorizationRequired
            }
            guard case .usernamePassword = stored else {
                throw ResourceAccessError.unsupported("SMB requires username/password credentials")
            }
            credential = stored
        } else { credential = nil } // Deliberate guest access, no fallback after rejected credentials.
        try Task.checkCancellation()
        return SMBRequest(configuration: configuration, path: resolved, credential: credential)
    }

    private func metadata(_ info: SMBFileInfo) throws -> ResourceMetadata {
        guard info.size.map({ $0 >= 0 }) ?? true else {
            throw ResourceAccessError.invalidResponse("Negative SMB file size")
        }
        guard info.kind != .symbolicLink, info.kind != .other else {
            throw ResourceAccessError.unsupported("SMB links and special files are not exposed")
        }
        return ResourceMetadata(size: info.size, isDirectory: info.kind == .directory,
            revision: ResourceRevision(size: info.size, modifiedAt: info.modifiedAt, contentHash: info.contentHash))
    }

    public func metadata(at path: ResourcePath) async throws -> ResourceMetadata {
        do {
            let request = try await request(for: path)
            let info = try await transport.stat(request)
            try Task.checkCancellation()
            return try metadata(info)
        } catch { throw classifySMBError(error) }
    }

    public func listChildren(at path: ResourcePath) async throws -> [ResourceEntry] {
        do {
            let request = try await request(for: path)
            let parent = try metadata(await transport.stat(request))
            guard parent.isDirectory else { throw ResourceAccessError.invalidPath("SMB listing requires a directory") }
            let children = try await transport.listChildren(request)
            try Task.checkCancellation()
            guard children.count <= 100_000 else { throw ResourceAccessError.limitExceeded }
            var names = Set<String>()
            return try children.map { child in
                try SMBConnectionConfiguration.validateComponent(child.name)
                guard names.insert(child.name).inserted else {
                    throw ResourceAccessError.invalidResponse("Duplicate SMB child name")
                }
                return ResourceEntry(path: try path.appending(child.name), metadata: try metadata(child.info))
            }.sorted { $0.path.string < $1.path.string }
        } catch { throw classifySMBError(error) }
    }

    public func read(at path: ResourcePath, range: ByteRange,
                     expectedRevision: ResourceRevision? = nil) async throws -> ResourceChunk {
        do {
            let request = try await request(for: path)
            let before = try metadata(await transport.stat(request))
            guard !before.isDirectory else { throw ResourceAccessError.unsupported("Cannot read an SMB directory") }
            if let expectedRevision, before.revision.match(expectedRevision) == .different {
                throw ResourceAccessError.resourceChanged
            }
            try Task.checkCancellation()
            if let size = before.size, range.offset >= size {
                return ResourceChunk(data: Data(), offset: range.offset, totalLength: size, revision: before.revision)
            }
            let data = try await transport.read(request, range: range)
            try Task.checkCancellation()
            let after = try metadata(await transport.stat(request))
            try Task.checkCancellation()
            guard !after.isDirectory, before.revision.match(after.revision) != .different,
                  expectedRevision.map({ after.revision.match($0) != .different }) ?? true else {
                throw ResourceAccessError.resourceChanged
            }
            guard data.count <= range.length else { throw ResourceAccessError.invalidResponse("Oversized SMB read") }
            if let size = after.size {
                let wanted = min(Int64(range.length), max(0, size - range.offset))
                guard Int64(data.count) == wanted else { throw ResourceAccessError.invalidResponse("Unexpected short SMB read") }
            }
            return ResourceChunk(data: data, offset: range.offset, totalLength: after.size, revision: after.revision)
        } catch { throw classifySMBError(error) }
    }

    public func probe(at path: ResourcePath) async throws -> ResourceProbe {
        let info = try await metadata(at: path)
        if info.isDirectory {
            return ResourceProbe(metadata: info, residency: .remote,
                capabilities: ResourceCapabilities(sequentialRead: .unsupported, randomAccess: .unsupported,
                    directPlayback: .unsupported), playbackAccess: .unavailable)
        }
        var sequential: CapabilitySupport = .unknown
        var random: CapabilitySupport = .unknown
        if let size = info.size, size > 0 {
            let offset = min(size - 1, 4096)
            let sample = try await read(at: path, range: ByteRange(offset: offset, length: 1), expectedRevision: info.revision)
            guard sample.data.count == 1 else { throw ResourceAccessError.invalidResponse("SMB probe read returned no data") }
            sequential = .supported
            if offset > 0 { random = .supported }
        }
        return ResourceProbe(metadata: info, residency: .remote,
            capabilities: ResourceCapabilities(sequentialRead: sequential, randomAccess: random,
                directPlayback: .unsupported, accurateMediaSeek: .unknown, verifiedAt: Date()),
            playbackAccess: .byteReader(sourceID: connection.id, path: path))
    }
}
