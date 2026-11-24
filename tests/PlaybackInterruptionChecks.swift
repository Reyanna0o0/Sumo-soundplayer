import Foundation

@main
struct PlaybackInterruptionChecks {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            passed += 1
            print("PASS: \(name)")
        }
        let first = UUID(), second = UUID()

        // The reported scenario: explicitly paused before another app takes audio.
        var state = PlaybackInterruptionState()
        state.requestPlayback(itemID: first)
        state.cancelPlaybackIntent()
        state.begin(itemID: first, wasPlaying: false)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "already paused never resumes when other audio ends")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(state.isInterrupted, "interruption records separate recovery state")
        state.cancelPlaybackIntent()
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "pause during interruption revokes recovery")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "same playing item may resume when system permits")
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "duplicate ended cannot replay")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: first, systemAllowsResume: false, appIsActive: true), "missing resume permission stays paused")
        state.begin(itemID: first, wasPlaying: false)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "later unrelated audio cannot revive old intent")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        state.begin(itemID: first, wasPlaying: false)
        check(state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "duplicate began preserves eligible interrupted playback")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        state.cancelPlaybackIntent()
        state.begin(itemID: first, wasPlaying: false)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "duplicate began cannot resurrect cancelled intent")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: second, systemAllowsResume: true, appIsActive: true), "changed item never inherits recovery")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        state.requestPlayback(itemID: second)
        check(!state.isInterrupted && !state.end(itemID: second, systemAllowsResume: true, appIsActive: true), "explicit new playback supersedes delayed ended")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: false)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "loading without playback cannot auto resume")

        state = PlaybackInterruptionState()
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "engine state alone cannot invent playback intent")
        check(!state.end(itemID: nil, systemAllowsResume: true, appIsActive: true), "ended without a began is ignored")

        // The system may never deliver ended. A fresh explicit remote Play
        // follows requestPlayback, independently of automatic recovery.
        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        state.requestPlayback(itemID: first)
        check(!state.isInterrupted, "fresh explicit Play works without a matching ended notification")
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "late ended after explicit Play cannot cause a second resume")
        state.begin(itemID: first, wasPlaying: true)
        state.cancelPlaybackIntent()
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "new Pause after explicit recovery still revokes automatic playback")

        // Regardless of shouldResume, audio must never restart just because
        // another app stops while this app is backgrounded or inactive.
        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: false), "background ended never starts previously playing audio")
        check(!state.isInterrupted, "background ended consumes the interruption rather than waiting for foreground")
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "returning active and receiving a duplicate ended cannot revive playback")
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "a later unrelated interruption cannot reuse revoked background intent")
        state.requestPlayback(itemID: first)
        check(!state.isInterrupted, "fresh explicit headset or lock-screen Play remains possible after background ending")
        state.begin(itemID: first, wasPlaying: true)
        check(state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "fresh explicit playback establishes new foreground recovery intent")

        state.requestPlayback(itemID: first)
        state.begin(itemID: first, wasPlaying: true)
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: false), "inactive ended also stays paused")
        check(!state.end(itemID: first, systemAllowsResume: true, appIsActive: true), "inactive candidate cannot survive until a later active ended")

        // Both MPRemoteCommand and PiP use this arrival-time epoch gate.
        let commands = AudioRemoteCommandGate()
        let beforePause = commands.capture()
        commands.transition(allowsAudio: true)
        check(!commands.accepts(beforePause), "queued play cannot cross explicit pause")
        check(commands.accepts(commands.capture()), "fresh headset or lock-screen command remains usable")

        let beforeInterruption = commands.capture()
        commands.transition(allowsAudio: true)
        check(!commands.accepts(beforeInterruption), "interruption start invalidates earlier command")
        let duringInterruption = commands.capture()
        commands.transition(allowsAudio: true)
        check(!commands.accepts(duringInterruption), "interruption end invalidates delayed system play")
        check(commands.accepts(commands.capture()), "fresh PiP control remains usable after interruption")

        let beforePreview = commands.capture()
        commands.transition(allowsAudio: false)
        let duringPreview = commands.capture()
        check(!commands.accepts(beforePreview) && !commands.accepts(duringPreview), "video preview cannot resume underlying audio")
        commands.transition(allowsAudio: true)
        check(!commands.accepts(duringPreview), "preview-era command stays invalid after dismissal")
        check(commands.accepts(commands.capture()), "new control works after preview dismissal")
        print("Playback interruption checks: \(passed) passed, 0 failed")
    }
}
