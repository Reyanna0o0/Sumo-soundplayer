import Foundation

/// System permission to resume is not a request to play. Keep the last explicit
/// playback intent separate from the engine, which iOS can stop independently.
struct PlaybackInterruptionState {
    private(set) var isInterrupted = false
    private var requestedItemID: UUID?
    private var interruptedItemID: UUID?

    mutating func requestPlayback(itemID: UUID?) {
        requestedItemID = itemID
        interruptedItemID = nil
        // An explicit new start supersedes the old interruption. A delayed
        // ended notification must not resume that old session a second time.
        isInterrupted = false
    }

    mutating func cancelPlaybackIntent() {
        requestedItemID = nil
        interruptedItemID = nil
    }

    mutating func begin(itemID: UUID?, wasPlaying: Bool) {
        guard !isInterrupted else { return }
        isInterrupted = true
        interruptedItemID = wasPlaying && requestedItemID == itemID ? itemID : nil
    }

    mutating func end(itemID: UUID?, systemAllowsResume: Bool, appIsActive: Bool) -> Bool {
        guard isInterrupted else { return false }
        isInterrupted = false
        let candidate = interruptedItemID
        interruptedItemID = nil
        // Background/inactive interruption endings never start audio. Consume
        // the candidate now, so returning to the app cannot revive it later.
        let resume = appIsActive && systemAllowsResume && candidate != nil
            && candidate == itemID && requestedItemID == itemID
        if !resume { requestedItemID = nil }
        return resume
    }
}
