import Foundation
import XCTest
import ResourceAccessCore
import PlaybackCoordination

@MainActor
final class PlaybackReconnectTests: XCTestCase {
    func testFailedRestoreSeekKeepsResumeTargetForNextReconnect() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        backend.emit(.position(milliseconds: 47_890, durationMilliseconds: 180_000))
        let first = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        backend.failSeek(ResourceAccessError.timedOut)
        await first.value
        XCTAssertEqual(coordinator.actualState, .failed)
        XCTAssertEqual(coordinator.positionMilliseconds, 47_890)
        let second = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        XCTAssertEqual(backend.seekTargets, [47_890, 47_890])
        backend.completeSeek()
        await second.value
        XCTAssertEqual(coordinator.positionMilliseconds, 47_890)
        XCTAssertEqual(backend.playCalls.count, 2)
    }

    func testReconnectFailureCanBeRetriedWithOriginalRevisionAndTime() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let original = playbackResource()
        await playbackLoad(coordinator, resolver: resolver, backend: backend, resource: original)
        backend.emit(.position(milliseconds: 33_000, durationMilliseconds: 180_000))
        let failed = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.failure(ResourceAccessError.temporarilyUnavailable))
        await failed.value
        XCTAssertEqual(coordinator.actualState, .failed)
        coordinator.pause()
        let retry = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        XCTAssertEqual(resolver.requests.last?.1, original.probe.metadata.revision)
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        XCTAssertEqual(backend.seekTargets, [33_000])
        backend.completeSeek()
        await retry.value
        XCTAssertEqual(coordinator.positionMilliseconds, 33_000)
        XCTAssertEqual(coordinator.actualState, .paused)
        XCTAssertEqual(backend.playCalls.count, 1)
    }

    func testReconnectResolvesStableIdentityRestoresTimeButRespectsSleep() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let original = playbackResource()
        await playbackLoad(coordinator, resolver: resolver, backend: backend, resource: original)
        backend.emit(.playing)
        backend.emit(.position(milliseconds: 72_315, durationMilliseconds: 180_000))
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        XCTAssertEqual(resolver.requests.last?.0, playbackTrack)
        XCTAssertEqual(resolver.requests.last?.1, original.probe.metadata.revision)
        coordinator.sleepTimerExpired()
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        XCTAssertEqual(backend.seekTargets, [72_315])
        backend.completeSeek(actual: 72_314)
        await recovery.value
        XCTAssertEqual(coordinator.positionMilliseconds, 72_314)
        XCTAssertEqual(coordinator.intent, .paused)
        XCTAssertEqual(coordinator.actualState, .paused)
        XCTAssertEqual(backend.playCalls.count, 1)
    }

    func testStopDuringReconnectReleasesResolvedResourceWithoutLoading() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        coordinator.stop()
        let lease = PlaybackTestLease()
        resolver.complete(.success(playbackResource(lease: lease)))
        await recovery.value
        XCTAssertEqual(coordinator.actualState, .idle)
        XCTAssertEqual(backend.loadedResources.count, 1)
        let releases = await lease.releases
        XCTAssertEqual(releases, 1)
    }

    func testChangedRevisionCannotResumeOldPosition() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        backend.emit(.position(milliseconds: 50_000, durationMilliseconds: 180_000))
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(revision: .init(size: 1000, etag: "\"v2\""))))
        await recovery.value
        XCTAssertEqual(coordinator.error, .resourceRevisionChanged)
        XCTAssertEqual(coordinator.actualState, .failed)
        XCTAssertEqual(backend.loadedResources.count, 1)
        XCTAssertTrue(backend.seekTargets.isEmpty)
        XCTAssertEqual(coordinator.identity, playbackTrack)
    }

    func testSameETagOnDifferentSourceDoesNotProveSameContent() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(sourceID: UUID())))
        await recovery.value
        XCTAssertEqual(coordinator.error, .resourceRevisionUnverified)
        XCTAssertEqual(backend.loadedResources.count, 1)
    }

    func testContentHashAllowsRebindingSourceWhileKeepingTrackAndTime() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let revision = ResourceRevision(size: 1000, contentHash: "fixture-sha256")
        await playbackLoad(coordinator, resolver: resolver, backend: backend, resource: playbackResource(revision: revision))
        backend.emit(.position(milliseconds: 24_500, durationMilliseconds: 180_000))
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        let replacement = playbackResource(revision: revision, sourceID: UUID(), path: "new/audio.mp3")
        resolver.complete(.success(replacement))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        backend.completeSeek()
        await recovery.value
        XCTAssertEqual(coordinator.identity, playbackTrack)
        XCTAssertEqual(coordinator.resource?.location, replacement.location)
        XCTAssertEqual(coordinator.positionMilliseconds, 24_500)
        XCTAssertEqual(backend.playCalls.count, 2)
    }

    func testReconnectCanUseCompleteLocalCopyAfterStoppingRemote() async {
        let resolver = PlaybackTestResolver(), log = PlaybackOperationLog()
        let remote = PlaybackTestBackend(.remoteStream, log: log), local = PlaybackTestBackend(.localFile, log: log)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [remote, local])
        await playbackLoad(coordinator, resolver: resolver, backend: remote)
        remote.emit(.position(milliseconds: 15_000, durationMilliseconds: 180_000))
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(local: true)))
        await playbackWait { local.pendingLoads.count == 1 }
        local.completeLoad()
        await playbackWait { local.pendingSeeks.count == 1 }
        local.completeSeek()
        await recovery.value
        XCTAssertEqual(coordinator.activeBackendKind, .localFile)
        XCTAssertEqual(coordinator.positionMilliseconds, 15_000)
        XCTAssertEqual(local.playCalls.count, 1)
        XCTAssertLessThan(log.values.firstIndex(of: "remoteStream.stop")!, log.values.firstIndex(of: "localFile.load")!)
    }

    func testPartialOrUnprovenLocalCopyNeverReachesLocalBackend() async {
        let resolver = PlaybackTestResolver(), remote = PlaybackTestBackend(.remoteStream), local = PlaybackTestBackend(.localFile)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [remote, local])
        await playbackLoad(coordinator, resolver: resolver, backend: remote)
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(local: true, residency: .unknown)))
        await recovery.value
        XCTAssertEqual(coordinator.error, .incompleteLocalResource)
        XCTAssertEqual(coordinator.actualState, .failed)
        XCTAssertTrue(local.loadedResources.isEmpty)
    }

    func testUserSeekDuringReconnectRestoreSupersedesSavedPosition() async throws {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        backend.emit(.position(milliseconds: 10_000, durationMilliseconds: 180_000))
        let recovery = Task { await coordinator.reconnect() }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad()
        await playbackWait { backend.pendingSeeks.count == 1 }
        try coordinator.seek(toMilliseconds: 90_000)
        coordinator.pause()
        backend.completeSeek()
        await playbackWait { backend.seekTargets.count == 2 }
        XCTAssertEqual(backend.seekTargets, [10_000, 90_000])
        backend.completeSeek()
        await recovery.value
        await playbackWait { coordinator.requestedSeekMilliseconds == nil }
        XCTAssertEqual(coordinator.positionMilliseconds, 90_000)
        XCTAssertEqual(coordinator.actualState, .paused)
        XCTAssertEqual(backend.playCalls.count, 1)
    }
}
