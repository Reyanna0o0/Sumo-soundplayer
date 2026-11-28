import Foundation
import XCTest
import ResourceAccessCore
import PlaybackCoordination

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testCancelledSelectionDoesNotPlayAndReleasesLeaseOnce() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let lease = PlaybackTestLease()
        let selecting = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        selecting.cancel()
        resolver.complete(.success(playbackResource(lease: lease)))
        await selecting.value
        XCTAssertEqual(coordinator.actualState, .idle)
        XCTAssertTrue(backend.loadedResources.isEmpty)
        let releases = await lease.releases
        XCTAssertEqual(releases, 1)
    }

    func testPauseWinsOverPendingResolveAndLoad() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let selecting = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        coordinator.pause()
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        coordinator.sleepTimerExpired()
        backend.completeLoad()
        await selecting.value
        XCTAssertEqual(coordinator.intent, .paused)
        XCTAssertEqual(coordinator.actualState, .paused)
        XCTAssertTrue(backend.playCalls.isEmpty)
        backend.emit(.playing)
        XCTAssertEqual(coordinator.actualState, .paused, "Late renderer event cannot override user pause")
    }

    func testStopRejectsOldLoadCompletionAndOldEvents() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let selecting = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        let stale = backend.pendingLoads[0].context
        coordinator.stop()
        backend.completeLoad()
        await selecting.value
        backend.emit(.playing, context: stale)
        backend.emit(.position(milliseconds: 9_000, durationMilliseconds: 180_000), context: stale)
        XCTAssertEqual(coordinator.actualState, .idle)
        XCTAssertEqual(coordinator.intent, .stopped)
        XCTAssertNil(coordinator.activeBackendKind)
        XCTAssertNil(coordinator.identity)
        XCTAssertEqual(coordinator.positionMilliseconds, 0)
        XCTAssertTrue(backend.playCalls.isEmpty)
    }

    func testNewSelectionExcludesOldBackendAndReleasesLease() async {
        let resolver = PlaybackTestResolver(), log = PlaybackOperationLog()
        let local = PlaybackTestBackend(.localFile, log: log), remote = PlaybackTestBackend(.remoteStream, log: log)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [local, remote])
        let lease = PlaybackTestLease()
        let a = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(local: true, lease: lease)))
        await playbackWait { local.pendingLoads.count == 1 }
        let oldContext = local.pendingLoads[0].context
        let second = TrackIdentity(workID: 7, trackID: 12)
        let b = Task { await coordinator.select(second) }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource(identity: second)))
        await playbackWait { remote.pendingLoads.count == 1 }
        remote.completeLoad()
        await b.value
        local.completeLoad()
        await a.value
        local.emit(.playing, context: oldContext)
        XCTAssertEqual(coordinator.identity, second)
        XCTAssertEqual(coordinator.activeBackendKind, .remoteStream)
        XCTAssertTrue(local.playCalls.isEmpty)
        XCTAssertEqual(remote.playCalls.count, 1)
        XCTAssertLessThan(log.values.firstIndex(of: "localFile.stop")!, log.values.firstIndex(of: "remoteStream.load")!)
        let releases = await lease.releases
        XCTAssertEqual(releases, 1)
    }

    func testSeeksAreSerialAndCoalesceLatestWithoutTransientResume() async throws {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        backend.emit(.playing)
        backend.emit(.position(milliseconds: 2_000, durationMilliseconds: 180_000))
        try coordinator.seek(toMilliseconds: 10_000)
        await playbackWait { backend.pendingSeeks.count == 1 }
        let firstContext = backend.pendingSeeks[0].context
        try coordinator.seek(toMilliseconds: 20_000)
        try coordinator.seek(toMilliseconds: 30_000)
        XCTAssertEqual(backend.seekTargets, [10_000])
        XCTAssertEqual(coordinator.subtitlePositionMilliseconds, 2_000)
        backend.completeSeek(actual: 10_005)
        await playbackWait { backend.seekTargets.count == 2 }
        XCTAssertEqual(backend.seekTargets, [10_000, 30_000])
        XCTAssertEqual(coordinator.positionMilliseconds, 2_000)
        XCTAssertEqual(backend.playCalls.count, 1, "Do not play between superseded seeks")
        backend.completeSeek(actual: 30_004)
        await playbackWait { coordinator.requestedSeekMilliseconds == nil }
        XCTAssertEqual(coordinator.positionMilliseconds, 30_004)
        XCTAssertEqual(backend.playCalls.count, 2)
        backend.emit(.position(milliseconds: 10_005, durationMilliseconds: 180_000), context: firstContext)
        backend.emit(.ended, context: firstContext)
        XCTAssertEqual(coordinator.positionMilliseconds, 30_004)
        XCTAssertEqual(coordinator.intent, .playing)
    }

    func testPauseAndStopWinOverInFlightSeek() async throws {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.localFile)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        await playbackLoad(coordinator, resolver: resolver, backend: backend, resource: playbackResource(local: true))
        try coordinator.seek(toMilliseconds: 45_000)
        await playbackWait { backend.pendingSeeks.count == 1 }
        coordinator.pause()
        backend.completeSeek()
        await playbackWait { coordinator.requestedSeekMilliseconds == nil }
        XCTAssertEqual(coordinator.actualState, .paused)
        XCTAssertEqual(coordinator.positionMilliseconds, 45_000)
        XCTAssertEqual(backend.playCalls.count, 1)
        try coordinator.seek(toMilliseconds: 60_000)
        await playbackWait { backend.pendingSeeks.count == 1 }
        coordinator.stop()
        backend.completeSeek()
        await Task.yield()
        XCTAssertEqual(coordinator.actualState, .idle)
        XCTAssertEqual(coordinator.positionMilliseconds, 0)
        XCTAssertEqual(backend.playCalls.count, 1)
    }

    func testWaitingDoesNotCountAndSubtitleUsesActualMediaTime() async throws {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream), clock = PlaybackTestClock()
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend], clock: { clock.now })
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        clock.now = 10
        XCTAssertEqual(coordinator.listeningSeconds, 0)
        backend.emit(.playing)
        try coordinator.setRate(1.5)
        clock.now = 14
        backend.emit(.position(milliseconds: 6_000, durationMilliseconds: 180_000))
        XCTAssertEqual(coordinator.subtitlePositionMilliseconds, 6_000)
        backend.emit(.waiting)
        clock.now = 39
        XCTAssertEqual(coordinator.listeningSeconds, 4, accuracy: 0.001)
        backend.emit(.playing)
        clock.now = 42
        backend.emit(.position(milliseconds: 10_500, durationMilliseconds: 180_000))
        coordinator.pause()
        clock.now = 100
        XCTAssertEqual(coordinator.listeningSeconds, 7, accuracy: 0.001)
        XCTAssertEqual(coordinator.subtitlePositionMilliseconds, 10_500)
    }

    func testPlayingStatusWithFrozenMediaClockDoesNotAccumulateListening() async throws {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream), clock = PlaybackTestClock()
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend], clock: { clock.now })
        await playbackLoad(coordinator, resolver: resolver, backend: backend)
        try coordinator.setRate(1.5)
        backend.emit(.playing)
        clock.now = 100
        XCTAssertEqual(coordinator.listeningSeconds, 0, "No getter extrapolation from playing status")
        backend.emit(.position(milliseconds: 0, durationMilliseconds: 180_000))
        clock.now = 105
        backend.emit(.position(milliseconds: 1_500, durationMilliseconds: 180_000))
        XCTAssertEqual(coordinator.listeningSeconds, 1, accuracy: 0.001, "A small advance cannot credit the whole stalled interval")
        try coordinator.setRate(2)
        clock.now = 107
        backend.emit(.position(milliseconds: 5_500, durationMilliseconds: 180_000))
        XCTAssertEqual(coordinator.listeningSeconds, 3, accuracy: 0.001, "Two times speed does not double wall seconds")
        clock.now = 1_000
        XCTAssertEqual(coordinator.listeningSeconds, 3, accuracy: 0.001)
    }

    func testLoadFailureStaysOnSameTrackWithoutQueueAdvance() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let selecting = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.completeLoad(.failure(ResourceAccessError.temporarilyUnavailable))
        await selecting.value
        XCTAssertEqual(coordinator.identity, playbackTrack)
        XCTAssertEqual(coordinator.actualState, .failed)
        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertTrue(backend.playCalls.isEmpty)
        XCTAssertNotNil(coordinator.error)
    }

    func testFailureEventDuringLoadCannotBeOverwrittenByLateSuccess() async {
        let resolver = PlaybackTestResolver(), backend = PlaybackTestBackend(.remoteStream)
        let coordinator = PlaybackCoordinator(resolver: resolver, backends: [backend])
        let selecting = Task { await coordinator.select(playbackTrack) }
        await playbackWait { resolver.pending.count == 1 }
        resolver.complete(.success(playbackResource()))
        await playbackWait { backend.pendingLoads.count == 1 }
        backend.emit(.failed(message: "Transport lost"))
        backend.completeLoad()
        await selecting.value
        XCTAssertEqual(coordinator.actualState, .failed)
        XCTAssertTrue(backend.playCalls.isEmpty)
    }
}
