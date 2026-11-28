import Foundation
import XCTest
import ResourceAccessCore
import PlaybackCoordination

@MainActor
final class PlaybackTestResolver: ResourceResolver {
    struct Request {
        let identity: TrackIdentity
        let expectedRevision: ResourceRevision?
        let continuation: CheckedContinuation<ResolvedResource, Error>
    }
    var pending: [Request] = []
    var requests: [(TrackIdentity, ResourceRevision?)] = []
    func resolve(_ identity: TrackIdentity, expectedRevision: ResourceRevision?) async throws -> ResolvedResource {
        requests.append((identity, expectedRevision))
        // Intentionally ignores cancellation: the coordinator must reject stale completion.
        return try await withCheckedThrowingContinuation { pending.append(.init(identity: identity, expectedRevision: expectedRevision, continuation: $0)) }
    }
    func complete(_ result: Result<ResolvedResource, Error>, index: Int = 0) {
        guard pending.indices.contains(index) else { XCTFail("No pending resolve"); return }
        pending.remove(at: index).continuation.resume(with: result)
    }
}

@MainActor
final class PlaybackOperationLog {
    var values: [String] = []
}

@MainActor
final class PlaybackTestBackend: PlaybackBackend {
    struct Load {
        let resource: ResolvedResource
        let context: PlaybackContext
        let continuation: CheckedContinuation<PlaybackBackendSnapshot, Error>
    }
    struct Seek {
        let target: Int64
        let context: PlaybackContext
        let continuation: CheckedContinuation<PlaybackBackendSnapshot, Error>
    }
    let kind: PlaybackBackendKind
    var eventHandler: (@MainActor (PlaybackBackendEvent) -> Void)?
    var pendingLoads: [Load] = []
    var pendingSeeks: [Seek] = []
    var loadedResources: [ResolvedResource] = []
    var seekTargets: [Int64] = []
    var playCalls: [(Double, PlaybackContext)] = []
    var pauseCalls: [PlaybackContext] = []
    var stopCalls = 0
    var latestContext: PlaybackContext?
    let log: PlaybackOperationLog

    init(_ kind: PlaybackBackendKind, log: PlaybackOperationLog? = nil) {
        self.kind = kind
        self.log = log ?? PlaybackOperationLog()
    }
    func load(_ resource: ResolvedResource, context: PlaybackContext) async throws -> PlaybackBackendSnapshot {
        latestContext = context
        loadedResources.append(resource)
        log.values.append("\(kind.rawValue).load")
        return try await withCheckedThrowingContinuation { pendingLoads.append(.init(resource: resource, context: context, continuation: $0)) }
    }
    func seek(toMilliseconds target: Int64, context: PlaybackContext) async throws -> PlaybackBackendSnapshot {
        latestContext = context
        seekTargets.append(target)
        log.values.append("\(kind.rawValue).seek")
        return try await withCheckedThrowingContinuation { pendingSeeks.append(.init(target: target, context: context, continuation: $0)) }
    }
    func play(rate: Double, context: PlaybackContext) {
        playCalls.append((rate, context))
        log.values.append("\(kind.rawValue).play")
    }
    func pause(context: PlaybackContext) { pauseCalls.append(context) }
    func stop() { stopCalls += 1; latestContext = nil; log.values.append("\(kind.rawValue).stop") }
    func completeLoad(_ result: Result<PlaybackBackendSnapshot, Error> = .success(playbackSnapshot()), index: Int = 0) {
        guard pendingLoads.indices.contains(index) else { XCTFail("No pending load"); return }
        pendingLoads.remove(at: index).continuation.resume(with: result)
    }
    func completeSeek(actual: Int64? = nil, index: Int = 0) {
        guard pendingSeeks.indices.contains(index) else { XCTFail("No pending seek"); return }
        let seek = pendingSeeks.remove(at: index)
        seek.continuation.resume(returning: playbackSnapshot(actual ?? seek.target))
    }
    func failSeek(_ error: Error, index: Int = 0) {
        guard pendingSeeks.indices.contains(index) else { XCTFail("No pending seek"); return }
        pendingSeeks.remove(at: index).continuation.resume(throwing: error)
    }
    func emit(_ signal: PlaybackBackendSignal, context: PlaybackContext? = nil) {
        guard let context = context ?? latestContext else { XCTFail("No event context"); return }
        eventHandler?(.init(context: context, signal: signal))
    }
}

func playbackSnapshot(_ position: Int64 = 0) -> PlaybackBackendSnapshot {
    .init(positionMilliseconds: position, durationMilliseconds: 180_000,
          capabilities: .init(canSeek: true, rateRange: 0.5...2))
}

let playbackTrack = TrackIdentity(workID: 7, trackID: 11)
let playbackSource = UUID(uuidString: "AE152233-60C7-4D99-A39B-A045877D8A04")!

func playbackResource(identity: TrackIdentity = playbackTrack, local: Bool = false,
                      residency: ResourceResidency? = nil,
                      revision: ResourceRevision = .init(size: 1000, etag: "\"v1\""),
                      sourceID: UUID = playbackSource, path: String = "audio.mp3",
                      lease: (any ResourceLease)? = nil) -> ResolvedResource {
    .init(identity: identity, location: .init(sourceID: sourceID, path: try! ResourcePath(path)),
          probe: .init(metadata: .init(size: revision.size, revision: revision),
                       residency: residency ?? (local ? .applicationOwnedComplete : .remote),
                       capabilities: .init(sequentialRead: .supported, randomAccess: .supported, directPlayback: .supported),
                       playbackAccess: local ? .localFile(URL(fileURLWithPath: "/verified/audio.mp3")) : .httpURL(URL(string: "https://example.invalid/audio.mp3")!)),
          lease: lease)
}

@MainActor
final class PlaybackTestClock {
    var now: TimeInterval = 0
}

actor PlaybackTestLease: ResourceLease {
    private(set) var releases = 0
    func release() { releases += 1 }
}

@MainActor
func playbackWait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for a controlled operation", file: file, line: line)
}

@MainActor
func playbackLoad(_ coordinator: PlaybackCoordinator, resolver: PlaybackTestResolver,
                  backend: PlaybackTestBackend, resource: ResolvedResource = playbackResource()) async {
    let operation = Task { await coordinator.select(resource.identity) }
    await playbackWait { resolver.pending.count == 1 }
    resolver.complete(.success(resource))
    await playbackWait { backend.pendingLoads.count == 1 }
    backend.completeLoad()
    await operation.value
}
