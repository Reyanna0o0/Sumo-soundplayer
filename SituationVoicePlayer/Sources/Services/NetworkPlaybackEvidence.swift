import Foundation

/// Wall seconds supported by advancing media samples. No getter extrapolation,
/// and no claim of acoustic measurement. Seek and state changes reset the baseline.
struct NetworkPlaybackEvidence {
    private struct Sample { let uptime: Double; let position: Int; let rate: Double }
    private var previous: Sample?
    private(set) var seconds: Double = 0

    mutating func resetBaseline() { previous = nil }

    mutating func sample(positionMS: Int, uptime: Double, rate: Double, advancing: Bool) {
        guard advancing, positionMS >= 0, uptime.isFinite, rate.isFinite, rate > 0 else {
            previous = nil; return
        }
        if let previous, positionMS > previous.position, uptime > previous.uptime,
           previous.rate == rate {
            seconds += min(uptime - previous.uptime, Double(positionMS - previous.position) / 1_000 / rate)
        }
        // Frozen samples advance the baseline too, so a later jump cannot count
        // the whole preceding stall as listening time.
        previous = Sample(uptime: uptime, position: positionMS, rate: rate)
    }
}

/// One seek in flight; multiple new drags coalesce to the last target. A load
/// invalidates all old tickets. Playback intent is deliberately held separately.
struct NetworkSeekQueue {
    struct Request: Equatable { let id = UUID(); let milliseconds: Int }
    private(set) var active: Request?
    private(set) var pending: Int?
    var isSeeking: Bool { active != nil || pending != nil }
    var latestTarget: Int? { pending ?? active?.milliseconds }

    mutating func enqueue(_ milliseconds: Int) { pending = max(0, milliseconds) }
    mutating func beginNext() -> Request? {
        guard active == nil, let pending else { return nil }
        let request = Request(milliseconds: pending)
        self.pending = nil; active = request
        return request
    }
    @discardableResult mutating func finish(_ id: UUID) -> Bool {
        guard active?.id == id else { return false }
        active = nil; return true
    }
    mutating func invalidate() { active = nil; pending = nil }
}
