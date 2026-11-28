import Foundation
import ResourceAccessCore

/// The future AVAudioEngine and AVPlayer adapters implement only this boundary.
/// Audio-session ownership, queue choice, persistence and UI remain outside it.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var eventHandler: (@MainActor (PlaybackBackendEvent) -> Void)? { get set }

    /// Prepare PAUSED. Never start sound as a side effect of load or seek.
    /// Stop must invalidate pending work inside the adapter too: ignoring an old
    /// callback in the coordinator cannot prevent an adapter replacing its new item.
    func load(_ resource: ResolvedResource, context: PlaybackContext) async throws -> PlaybackBackendSnapshot
    func seek(toMilliseconds: Int64, context: PlaybackContext) async throws -> PlaybackBackendSnapshot
    func play(rate: Double, context: PlaybackContext)
    func pause(context: PlaybackContext)
    func stop()
}
