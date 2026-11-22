import Foundation

/// The countdown follows elapsed time, including time spent locked or interrupted.
public enum PlaybackSleepTimer: Equatable, Sendable {
    case off
    case deadline(ContinuousClock.Instant)
    case endOfTrack(UUID)
    /// A particular occurrence in the current queue, rather than a media ID.
    case endOfQueueItem(UUID)

    public static let minutesRange = 1...720

    public static func deadline(minutes: Int, from now: ContinuousClock.Instant) -> PlaybackSleepTimer? {
        guard minutesRange.contains(minutes) else { return nil }
        return .deadline(now.advanced(by: .seconds(minutes * 60)))
    }

    public var queueTargetID: UUID? {
        if case .endOfQueueItem(let id) = self { return id }
        return nil
    }

    /// Keep timers attached to reachable entries. A move that takes the target
    /// behind the playing entry cancels it, rather than leaving a stale timer.
    public func retainingValidTarget(in queue: PlaybackQueue) -> PlaybackSleepTimer {
        switch self {
        case .off, .deadline: return self
        case .endOfTrack(let id): return queue.current?.id == id ? self : .off
        case .endOfQueueItem(let id):
            guard let position = queue.order.firstIndex(where: { queue.items[$0].id == id }),
                  position >= queue.cursor else { return .off }
            return self
        }
    }

    /// Leaving the selected stopping track manually does not count as hearing
    /// its ending; clear it even if the selection wraps to the queue's start.
    public func afterManualSelection(from previousItemID: UUID?, in queue: PlaybackQueue) -> PlaybackSleepTimer {
        if case .endOfQueueItem(let id) = self,
           previousItemID == id, queue.current?.id != id { return .off }
        return retainingValidTarget(in: queue)
    }

    public func shouldStop(at now: ContinuousClock.Instant, finishedItemID: UUID? = nil) -> Bool {
        switch self {
        case .off: return false
        case .deadline(let deadline): return now >= deadline
        case .endOfTrack(let id), .endOfQueueItem(let id): return finishedItemID == id
        }
    }

    public func remainingSeconds(at now: ContinuousClock.Instant) -> Int? {
        guard case .deadline(let deadline) = self else { return nil }
        guard now < deadline else { return 0 }
        let duration = now.duration(to: deadline).components
        return Int(duration.seconds) + (duration.attoseconds > 0 ? 1 : 0)
    }
}
