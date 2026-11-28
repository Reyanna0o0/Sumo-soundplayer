import Foundation

@main enum NetworkPlaybackPolicyChecks {
    static func main() throws {
        var evidence = NetworkPlaybackEvidence()
        evidence.sample(positionMS: 0, uptime: 0, rate: 1, advancing: true)
        evidence.sample(positionMS: 1_000, uptime: 1, rate: 1, advancing: true)
        precondition(abs(evidence.seconds - 1) < 0.00001)
        // A reported "playing" clock frozen for 30 seconds adds no listening.
        evidence.sample(positionMS: 1_000, uptime: 31, rate: 1, advancing: true)
        precondition(abs(evidence.seconds - 1) < 0.00001)
        evidence.sample(positionMS: 2_000, uptime: 32, rate: 1, advancing: true)
        precondition(abs(evidence.seconds - 2) < 0.00001)
        evidence.sample(positionMS: 2_000, uptime: 33, rate: 1, advancing: false)
        evidence.sample(positionMS: 20_000, uptime: 63, rate: 1, advancing: true)
        precondition(abs(evidence.seconds - 2) < 0.00001)
        evidence.resetBaseline()
        evidence.sample(positionMS: 120_350, uptime: 64, rate: 1.5, advancing: true)
        evidence.sample(positionMS: 126_350, uptime: 68, rate: 1.5, advancing: true)
        precondition(abs(evidence.seconds - 6) < 0.00001) // Four wall seconds, not six media seconds.
        evidence.sample(positionMS: 127_850, uptime: 72, rate: 1.5, advancing: true)
        precondition(abs(evidence.seconds - 7) < 0.00001) // Underbuffered: cap by actual progress.
        evidence.resetBaseline()
        evidence.sample(positionMS: 17_250, uptime: 73, rate: 1.5, advancing: true)
        precondition(abs(evidence.seconds - 7) < 0.00001)

        var seeks = NetworkSeekQueue()
        seeks.enqueue(120_350)
        let forward = seeks.beginNext()!
        seeks.enqueue(43_000)
        seeks.enqueue(17_250)
        precondition(seeks.beginNext() == nil)
        precondition(seeks.latestTarget == 17_250)
        precondition(!seeks.finish(UUID()))
        precondition(seeks.finish(forward.id))
        let backward = seeks.beginNext()!
        precondition(backward.milliseconds == 17_250)
        seeks.invalidate()
        seeks.enqueue(9_000)
        let replacement = seeks.beginNext()!
        precondition(!seeks.finish(backward.id))
        precondition(seeks.active == replacement)
        precondition(seeks.finish(replacement.id))
        precondition(!seeks.isSeeking)

        let eof = try NetworkByteRangePlan(requestedOffset: 100, currentOffset: 100,
            requestedLength: 50, requestsToEnd: false, fileSize: 100)
        precondition(eof.start == 100 && eof.endExclusive == 100)
        let tail = try NetworkByteRangePlan(requestedOffset: 80, currentOffset: 90,
            requestedLength: 50, requestsToEnd: false, fileSize: 100)
        precondition(tail.start == 90 && tail.endExclusive == 100)
        precondition(tail.nextLength(at: 90, maximum: 128 * 1_024) == 10)
        let large = try NetworkByteRangePlan(requestedOffset: 0, currentOffset: 0,
            requestedLength: 1, requestsToEnd: true, fileSize: 100_000_000)
        precondition(large.nextLength(at: 0, maximum: 128 * 1_024) == 128 * 1_024)
        do {
            _ = try NetworkByteRangePlan(requestedOffset: Int64.max, currentOffset: 0,
                requestedLength: 1, requestsToEnd: false, fileSize: Int64.max)
            preconditionFailure("overflow was accepted")
        } catch NetworkLoaderFailure.invalidRange { }
        print("Network playback policy checks passed: frozen clocks, buffering, rates, seek coalescing, stale callbacks and bounded byte ranges.")
    }
}
