import Foundation

public struct ResourceBinding: Codable, Equatable, Sendable {
    public let identity: TrackIdentity
    public var locations: [ResourceLocation]
    public init(identity: TrackIdentity, locations: [ResourceLocation]) { self.identity = identity; self.locations = locations }
}
public struct ResourceCatalogSnapshot: Codable, Sendable {
    public let connections: [SourceConnection]
    public let bindings: [ResourceBinding]
    public init(connections: [SourceConnection], bindings: [ResourceBinding]) { self.connections = connections; self.bindings = bindings }
}

/// Owns locations only, never the app's work/creator/library metadata.
/// Removing a connection cannot delete a work, its classification or its progress.
public actor ResourceCatalog: ResourceResolver {
    private var connections: [UUID: SourceConnection] = [:]
    private var adapters: [UUID: any ResourceAdapter] = [:]
    private var bindings: [TrackIdentity: ResourceBinding] = [:]
    private var bindingGenerations: [TrackIdentity: UUID] = [:]
    private var sourceGenerations: [UUID: UUID] = [:]
    private let ownedFiles: OwnedResourceStore?
    public init(ownedFiles: OwnedResourceStore? = nil) { self.ownedFiles = ownedFiles }

    public func register(_ adapter: any ResourceAdapter) {
        connections[adapter.connection.id] = adapter.connection
        adapters[adapter.connection.id] = adapter
        sourceGenerations[adapter.connection.id] = UUID()
    }
    public func bind(_ binding: ResourceBinding) { bindings[binding.identity] = binding; bindingGenerations[binding.identity] = UUID() }
    public func binding(for identity: TrackIdentity) -> ResourceBinding? { bindings[identity] }
    public func disconnect(_ id: UUID) { adapters[id] = nil; sourceGenerations[id] = UUID() }
    public func removeConnection(_ id: UUID) { disconnect(id); connections[id] = nil }
    public func snapshot() -> ResourceCatalogSnapshot {
        .init(connections: Array(connections.values), bindings: Array(bindings.values))
    }
    public func restore(_ snapshot: ResourceCatalogSnapshot) throws {
        guard Set(snapshot.connections.map(\.id)).count == snapshot.connections.count,
              Set(snapshot.bindings.map(\.identity)).count == snapshot.bindings.count else {
            throw ResourceAccessError.invalidConfiguration("Duplicate persisted identity")
        }
        connections = Dictionary(uniqueKeysWithValues: snapshot.connections.map { ($0.id, $0) })
        bindings = Dictionary(uniqueKeysWithValues: snapshot.bindings.map { ($0.identity, $0) })
        // Reconstruct platform transports/Keychain externally. Never deserialize live sessions.
        adapters = [:]
        bindingGenerations = Dictionary(uniqueKeysWithValues: snapshot.bindings.map { ($0.identity, UUID()) })
        sourceGenerations = Dictionary(uniqueKeysWithValues: snapshot.connections.map { ($0.id, UUID()) })
    }

    public func resolve(_ identity: TrackIdentity, expectedRevision: ResourceRevision? = nil) async throws -> ResolvedResource {
        try Task.checkCancellation()
        let binding = bindings[identity]
        let bindingGeneration = bindingGenerations[identity]
        if let ownedFiles, let local = try await ownedFiles.resolve(identity) {
            try Task.checkCancellation()
            guard bindingGeneration == bindingGenerations[identity] else { throw ResourceAccessError.cancelled }
            let matchingOrigin = binding?.locations.first(where: { $0.sourceID == local.location.sourceID && $0.path == local.location.path })
            let revisionFits = [expectedRevision, matchingOrigin?.expectedRevision].compactMap { $0 }
                .allSatisfy { $0.match(local.probe.metadata.revision) != .different }
            let sameContentAtNewLocation = binding?.locations.contains {
                $0.expectedRevision?.contentMatchAcrossLocations(local.probe.metadata.revision) == .same
            } ?? false
            if revisionFits && (binding == nil || matchingOrigin != nil || sameContentAtNewLocation) {
                return local
            }
        }
        guard let binding, !binding.locations.isEmpty else { throw ResourceAccessError.notFound }
        var lastError: Error = ResourceAccessError.temporarilyUnavailable
        for location in binding.locations {
            try Task.checkCancellation()
            guard let adapter = adapters[location.sourceID] else { continue }
            let sourceGeneration = sourceGenerations[location.sourceID]
            do {
                let probe = try await adapter.probe(at: location.path)
                try Task.checkCancellation()
                guard bindingGeneration == bindingGenerations[identity],
                      sourceGeneration == sourceGenerations[location.sourceID] else { throw ResourceAccessError.cancelled }
                for expected in [expectedRevision, location.expectedRevision].compactMap({ $0 }) {
                    if expected.match(probe.metadata.revision) == .different { throw ResourceAccessError.resourceChanged }
                }
                switch probe.availability {
                case .ready: return .init(identity: identity, location: location, probe: probe)
                case .requiresAuthorization: throw ResourceAccessError.authorizationRequired
                case .missing: throw ResourceAccessError.notFound
                default: throw ResourceAccessError.temporarilyUnavailable
                }
            } catch is CancellationError { throw CancellationError() }
            catch ResourceAccessError.cancelled { throw ResourceAccessError.cancelled }
            catch { lastError = error }
        }
        throw lastError
    }
}
