import Foundation
import CryptoKit

public struct OwnedCopyRecord: Codable, Equatable, Sendable {
    public let identity: TrackIdentity
    public let origin: ResourceLocation
    public let fileName: String
    public let revision: ResourceRevision
    public init(identity: TrackIdentity, origin: ResourceLocation, fileName: String, revision: ResourceRevision) {
        self.identity = identity; self.origin = origin; self.fileName = fileName; self.revision = revision
    }
}

/// A small foreground copy implementation for adapter validation, not an iOS
/// background-download scheduler. Partial files are never registered as playable.
public actor OwnedResourceStore {
    private let directory: URL
    private var records: [TrackIdentity: OwnedCopyRecord] = [:]
    private var copyGenerations: [TrackIdentity: UUID] = [:]
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw ResourceAccessError.invalidConfiguration("Owned storage must be a file URL") }
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let index = self.directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            let saved = try JSONDecoder().decode([OwnedCopyRecord].self, from: Data(contentsOf: index))
            guard Set(saved.map(\.identity)).count == saved.count else { throw ResourceAccessError.invalidResponse("Duplicate offline identity") }
            for record in saved { try Self.validateFileName(record.fileName) }
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.identity, $0) })
        }
    }
    public func record(for identity: TrackIdentity) -> OwnedCopyRecord? { records[identity] }
    public func cancelCopy(for identity: TrackIdentity) { copyGenerations[identity] = UUID() }

    public func resolve(_ identity: TrackIdentity) throws -> ResolvedResource? {
        guard let record = records[identity] else { return nil }
        try Self.validateFileName(record.fileName)
        let url = directory.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == record.revision.size else { return nil }
        // A cached index digest must not become false evidence after equal-size corruption.
        guard let expectedHash = record.revision.contentHash,
              try Self.fileHash(url) == expectedHash.lowercased() else { return nil }
        return .init(identity: identity, location: record.origin,
            probe: .init(metadata: .init(size: record.revision.size, revision: record.revision),
                residency: .applicationOwnedComplete,
                capabilities: .init(sequentialRead: .supported, randomAccess: .supported,
                    completeDownload: .supported, directPlayback: .supported, verifiedAt: Date()),
                playbackAccess: .localFile(url)))
    }

    @discardableResult
    public func copy(from adapter: any ResourceAdapter, location: ResourceLocation,
                     identity: TrackIdentity, byteLimit: Int64, chunkSize: Int = 65_536) async throws -> OwnedCopyRecord {
        guard location.sourceID == adapter.connection.id, chunkSize > 0,
              chunkSize <= ByteRange.maximumLength, byteLimit > 0 else { throw ResourceAccessError.invalidConfiguration("Invalid copy request") }
        let operation = UUID()
        copyGenerations[identity] = operation
        try checkCurrentCopy(identity, operation)
        let initial = try await adapter.metadata(at: location.path)
        try checkCurrentCopy(identity, operation)
        guard !initial.isDirectory, let size = initial.size, size > 0 else { throw ResourceAccessError.unsupported("Copy requires a known nonempty file size") }
        guard size <= byteLimit else { throw ResourceAccessError.limitExceeded }
        if let expected = location.expectedRevision, expected.match(initial.revision) == .different { throw ResourceAccessError.resourceChanged }
        let expectedHashes = [location.expectedRevision?.contentHash, initial.revision.contentHash].compactMap { $0 }
        // Independent requests cannot establish a stable source snapshot from size/mtime.
        // A known content digest can verify the assembled bytes; a digest calculated
        // only AFTER copying cannot prove that different ranges came from one version.
        if size > Int64(chunkSize), initial.revision.strongETag == nil, expectedHashes.isEmpty {
            throw ResourceAccessError.unsupported("Multi-range copy requires a strong source validator or an expected SHA-256")
        }
        let requiresStrongRangeMatch = size > Int64(chunkSize) && expectedHashes.isEmpty
        let token = UUID().uuidString
        let temporary = directory.appendingPathComponent(".partial-" + token)
        let sourceExtension = (location.path.components.last ?? "").split(separator: ".").last.map(String.init) ?? "bin"
        let ext = sourceExtension.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil ? sourceExtension : "bin"
        let finalName = token + "." + ext
        let final = directory.appendingPathComponent(finalName)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ResourceAccessError.temporarilyUnavailable }
        let output = try FileHandle(forWritingTo: temporary)
        var published = false
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
            if !published { try? FileManager.default.removeItem(at: final) }
        }
        var offset: Int64 = 0
        var digest = SHA256()
        while offset < size {
            try checkCurrentCopy(identity, operation)
            let length = Int(min(Int64(chunkSize), size - offset))
            let range = try ByteRange(offset: offset, length: length)
            let chunk = try await adapter.read(at: location.path, range: range, expectedRevision: initial.revision)
            try checkCurrentCopy(identity, operation)
            guard chunk.offset == offset, chunk.data.count == length else { throw ResourceAccessError.invalidResponse("Truncated or displaced copy range") }
            if let total = chunk.totalLength, total != size { throw ResourceAccessError.resourceChanged }
            if initial.revision.match(chunk.revision) == .different { throw ResourceAccessError.resourceChanged }
            if requiresStrongRangeMatch, initial.revision.match(chunk.revision) != .same {
                throw ResourceAccessError.unsupported("Range response did not preserve the strong source validator")
            }
            try output.write(contentsOf: chunk.data)
            digest.update(data: chunk.data)
            offset += Int64(length)
        }
        let after = try await adapter.metadata(at: location.path)
        try checkCurrentCopy(identity, operation)
        guard after.size == size, initial.revision.match(after.revision) != .different else { throw ResourceAccessError.resourceChanged }
        if requiresStrongRangeMatch, initial.revision.match(after.revision) != .same {
            throw ResourceAccessError.unsupported("Final metadata did not preserve the strong source validator")
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        for expected in expectedHashes + [after.revision.contentHash].compactMap({ $0 }) {
            guard expected.lowercased() == hash else { throw ResourceAccessError.resourceChanged }
        }
        try output.synchronize(); try output.close()
        try FileManager.default.moveItem(at: temporary, to: final)
        let record = OwnedCopyRecord(identity: identity, origin: location, fileName: finalName,
            revision: .init(size: size, etag: initial.revision.etag, modifiedAt: initial.revision.modifiedAt, contentHash: hash))
        let previous = records[identity]
        records[identity] = record
        do { try JSONEncoder().encode(Array(records.values)).write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
        catch { records[identity] = previous; throw error }
        published = true
        // Old complete copies are intentionally not deleted here: an active engine
        // may hold one. A future lease-aware cache collector owns that decision.
        return record
    }

    private static func validateFileName(_ name: String) throws {
        let path = try ResourcePath(name)
        guard path.components.count == 1, !name.hasPrefix("."), name != "index.json" else { throw ResourceAccessError.invalidPath("Invalid owned-copy path") }
    }
    private static func fileHash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while let chunk = try input.read(upToCount: ByteRange.maximumLength), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func checkCurrentCopy(_ identity: TrackIdentity, _ operation: UUID) throws {
        try Task.checkCancellation()
        guard copyGenerations[identity] == operation else { throw ResourceAccessError.cancelled }
    }
}
