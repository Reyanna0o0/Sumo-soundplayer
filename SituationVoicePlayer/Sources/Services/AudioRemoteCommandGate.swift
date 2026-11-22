import Foundation

/// MPRemoteCommand callbacks may arrive off the main actor. Capture permission
/// at arrival; a command queued across video entry/exit must never become new.
final class AudioRemoteCommandGate: @unchecked Sendable {
    struct Ticket: Sendable {
        fileprivate let generation: UInt64
        let allowsAudio: Bool
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var allowsAudio = true

    func capture() -> Ticket {
        lock.lock(); defer { lock.unlock() }
        return Ticket(generation: generation, allowsAudio: allowsAudio)
    }

    func transition(allowsAudio: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        self.allowsAudio = allowsAudio
    }

    func accepts(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket.allowsAudio && allowsAudio && ticket.generation == generation
    }
}

enum AudioRemoteCommand: Sendable {
    case play, pause, toggle, next, previous
    case seek(Int)
}
