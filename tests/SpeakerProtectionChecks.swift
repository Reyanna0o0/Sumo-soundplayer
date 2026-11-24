import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func playingSpeaker(at time: TimeInterval = 0) -> SpeakerProtectionPolicy {
    var policy = SpeakerProtectionPolicy()
    policy.updateRoute(.speaker, id: "speaker", at: time)
    policy.beginPlayback(owner: "work", at: time)
    return policy
}

@main
struct SpeakerProtectionChecks {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ run: () throws -> Void) throws {
            do { try run(); passed += 1; print("PASS: \(name)") }
            catch { throw CheckFailure(description: "\(name): \(error)") }
        }

        try check("Unknown output is protected before playback") {
            let policy = SpeakerProtectionPolicy()
            try expect(policy.enabled && policy.isMuted, "Default and unknown-route protection must be on")
            try expect(policy.activeOwners.isEmpty, "Protection must not start playback")
        }

        try check("Starting on the speaker is muted even with nonzero system volume") {
            var policy = playingSpeaker(at: 10)
            policy.volumeChanged(from: 0.4, to: 0.8, routeID: "speaker", at: 10)
            try expect(policy.isMuted, "Initial/session-restored volume must not unlock the speaker")
        }

        try check("Volume adjustment unlocks only after the 0.75-second boundary") {
            var policy = playingSpeaker(at: 10)
            policy.volumeChanged(from: 0.4, to: 0.5, routeID: "speaker", at: 10.749)
            try expect(policy.isMuted, "A volume callback inside the guard window must be ignored")
            policy.volumeChanged(from: 0.5, to: 0.4, routeID: "speaker", at: 10.75)
            try expect(!policy.isMuted, "A stable-route volume-down action must unlock too")
            try expect(policy.activeOwners == ["work"], "Unmuting must not change playback ownership")
        }

        try check("Headphone connection while paused unmutes without starting playback") {
            var policy = SpeakerProtectionPolicy()
            policy.updateRoute(.speaker, id: "speaker", at: 0)
            policy.updateRoute(.other, id: "headphones", at: 1)
            try expect(!policy.isMuted, "Private output must not inherit speaker mute")
            try expect(policy.activeOwners.isEmpty, "Connecting headphones must not create playback")
        }

        try check("Playback starts normally on headphones") {
            var policy = SpeakerProtectionPolicy()
            policy.updateRoute(.other, id: "headphones", at: 0)
            policy.beginPlayback(owner: "work", at: 0)
            try expect(!policy.isMuted && policy.activeOwners == ["work"], "Headphone playback should stay unmuted")
        }

        try check("Returning from headphones rearms the previously allowed speaker") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            try expect(!policy.isMuted, "Explicit current-session permission should work")
            policy.updateRoute(.other, id: "headphones", at: 2)
            try expect(!policy.isMuted, "Connecting headphones should release mute")
            policy.updateRoute(.speaker, id: "speaker", at: 3)
            try expect(policy.isMuted, "Old speaker permission must not survive route departure")
            try expect(policy.activeOwners == ["work"], "Route handling must not change playback intent")
        }

        try check("A different speaker route requires fresh permission") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.updateRoute(.speaker, id: "other-speaker", at: 2)
            try expect(policy.isMuted, "Permission is scoped to one output route")
        }

        try check("Explicit pause and restart rearm protection") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.endPlayback(owner: "work")
            try expect(policy.isMuted && policy.activeOwners.isEmpty, "Pausing the final source must revoke permission")
            policy.beginPlayback(owner: "work", at: 5)
            try expect(policy.isMuted, "Restarting the same item must require fresh permission")
        }

        try check("Interruption revokes every source and does not resume any of them") {
            var policy = playingSpeaker()
            policy.beginPlayback(owner: "preview", at: 1)
            policy.allowCurrentSpeakerPlayback()
            policy.interrupt()
            try expect(policy.isMuted && policy.activeOwners.isEmpty, "Interruption must revoke all playback owners")
            policy.beginPlayback(owner: "work", at: 5)
            try expect(policy.isMuted, "A later legitimate resume must start protected")
        }

        try check("Continuous playback and track changes keep the current allowance") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.beginPlayback(owner: "work", at: 100)
            policy.updateRoute(.speaker, id: "speaker", at: 101)
            try expect(!policy.isMuted, "Idempotent begin and same-route refresh must not mute a continuous queue")
            try expect(policy.activeOwners == ["work"], "Repeated begin must not duplicate owners")
        }

        try check("Overlapping sources preserve allowance until the last source ends") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.beginPlayback(owner: "preview", at: 2)
            policy.endPlayback(owner: "work")
            try expect(!policy.isMuted && policy.activeOwners == ["preview"], "One source ending must not reset the active session")
            policy.endPlayback(owner: "preview")
            try expect(policy.isMuted && policy.activeOwners.isEmpty, "Last source ending must revoke allowance")
            policy.beginPlayback(owner: "opening", at: 10)
            try expect(policy.isMuted, "An independent later source must not inherit permission")
        }

        try check("Explicit permission cannot arm a future speaker session") {
            var policy = SpeakerProtectionPolicy()
            policy.updateRoute(.speaker, id: "speaker", at: 0)
            policy.allowCurrentSpeakerPlayback()
            try expect(policy.isMuted && policy.activeOwners.isEmpty, "Idle allowance must do nothing")
            policy.beginPlayback(owner: "work", at: 2)
            try expect(policy.isMuted, "Future playback must not inherit idle permission")
            policy.allowCurrentSpeakerPlayback()
            try expect(!policy.isMuted, "The explicit button may bypass the volume guard for current playback")
        }

        try check("Disabling protection releases mute and enabling restores it") {
            var policy = playingSpeaker()
            policy.setEnabled(false)
            try expect(!policy.enabled && !policy.isMuted, "Opt-out must allow output immediately")
            policy.setEnabled(true)
            try expect(policy.enabled && policy.isMuted, "Opt-in must revoke previous permission")
            try expect(policy.activeOwners == ["work"], "Changing protection must not start or stop playback")
        }

        try check("Disabled preference remains unmuted across routes and sessions") {
            var policy = SpeakerProtectionPolicy(enabled: false)
            policy.updateRoute(.speaker, id: "speaker", at: 0)
            policy.beginPlayback(owner: "work", at: 0)
            policy.updateRoute(.unknown, id: "", at: 1)
            policy.interrupt()
            try expect(!policy.isMuted, "Opt-out should not be overridden by lifecycle changes")
        }

        try check("Enabling protection while using headphones does not mute them") {
            var policy = SpeakerProtectionPolicy(enabled: false)
            policy.updateRoute(.other, id: "headphones", at: 0)
            policy.beginPlayback(owner: "work", at: 0)
            policy.setEnabled(true)
            try expect(!policy.isMuted, "The opt-in protects the speaker, not headphones")
            policy.updateRoute(.speaker, id: "speaker", at: 1)
            try expect(policy.isMuted, "Moving to the speaker must activate protection")
        }

        try check("Other apps changing volume while this app is paused cannot unlock") {
            var policy = playingSpeaker()
            policy.endPlayback(owner: "work")
            policy.volumeChanged(from: 0.2, to: 0.8, routeID: "speaker", at: 100)
            try expect(policy.isMuted && policy.activeOwners.isEmpty, "An idle volume callback is not consent to play this app aloud")
            policy.beginPlayback(owner: "work", at: 101)
            try expect(policy.isMuted, "Other-app volume must not transfer into the next session")
        }

        try check("Route-restored volume is ignored for a fresh 0.75-second window") {
            var policy = playingSpeaker()
            policy.updateRoute(.other, id: "headphones", at: 2)
            policy.updateRoute(.speaker, id: "speaker", at: 10)
            policy.volumeChanged(from: 0.1, to: 0.8, routeID: "speaker", at: 10.74)
            try expect(policy.isMuted, "Saved speaker volume restoration must not unlock")
            policy.volumeChanged(from: 0.8, to: 0.7, routeID: "speaker", at: 10.75)
            try expect(!policy.isMuted, "A later deliberate adjustment should work")
        }

        try check("Session activation notifications extend rather than shorten the guard") {
            var policy = playingSpeaker()
            policy.ignoreAutomaticVolumeChanges(at: 10)
            policy.ignoreAutomaticVolumeChanges(at: 9)
            policy.volumeChanged(from: 0.1, to: 0.8, routeID: "speaker", at: 10.74)
            try expect(policy.isMuted, "An older notification must not shorten the newest guard")
            policy.volumeChanged(from: 0.8, to: 0.7, routeID: "speaker", at: 10.75)
            try expect(!policy.isMuted, "Volume changes should work once the newest guard expires")
        }

        try check("Late callbacks from a different route are rejected") {
            var policy = playingSpeaker()
            policy.updateRoute(.other, id: "headphones", at: 1)
            policy.updateRoute(.speaker, id: "speaker", at: 2)
            policy.volumeChanged(from: 0.1, to: 0.8, routeID: "headphones", at: 20)
            try expect(policy.isMuted, "An old-route callback must not unlock the current speaker")
        }

        try check("Late callbacks from a finished session cannot unlock the next session") {
            var policy = playingSpeaker()
            policy.endPlayback(owner: "work")
            policy.beginPlayback(owner: "work", at: 20)
            policy.volumeChanged(from: 0.2, to: 0.8, routeID: "speaker", at: 10)
            try expect(policy.isMuted, "Arrival after resume must not turn an old event into fresh permission")
            policy.volumeChanged(from: 0.8, to: 0.7, routeID: "speaker", at: 21)
            try expect(!policy.isMuted, "A genuinely new session event should be accepted")
        }

        try check("Same route ID after disconnect still rejects pre-disconnect callbacks") {
            var policy = playingSpeaker()
            policy.updateRoute(.other, id: "headphones", at: 5)
            policy.updateRoute(.speaker, id: "speaker", at: 10)
            policy.volumeChanged(from: 0.2, to: 0.8, routeID: "speaker", at: 4)
            try expect(policy.isMuted, "Matching route ID alone must not validate a stale callback")
        }

        try check("NaN and infinite volume values cannot unlock protection") {
            for (old, new) in [(Float.nan, Float(0.5)), (Float(0.5), Float.nan), (Float.infinity, Float(0.5)), (Float(0.5), -Float.infinity)] {
                var policy = playingSpeaker()
                policy.volumeChanged(from: old, to: new, routeID: "speaker", at: 10)
                try expect(policy.isMuted, "Nonfinite volume is not a user adjustment")
            }
        }

        try check("Unchanged and negligible volume callbacks do not grant consent") {
            var policy = playingSpeaker()
            policy.volumeChanged(from: 0.5, to: 0.5, routeID: "speaker", at: 10)
            policy.volumeChanged(from: 0.5, to: 0.50001, routeID: "speaker", at: 11)
            try expect(policy.isMuted, "Repeated observations must not be treated as a volume-key press")
            policy.volumeChanged(from: 0.5, to: 0.6, routeID: "speaker", at: 12)
            try expect(!policy.isMuted, "A material volume adjustment should unlock")
        }

        try check("Unknown active routes stay protected and cannot be explicitly allowed") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.updateRoute(.unknown, id: "", at: 5)
            policy.allowCurrentSpeakerPlayback()
            policy.volumeChanged(from: 0.1, to: 0.8, routeID: "", at: 10)
            try expect(policy.isMuted, "Unknown output must fail closed even with an active source")
        }

        try check("Ending an unrelated owner does not revoke a live session") {
            var policy = playingSpeaker()
            policy.allowCurrentSpeakerPlayback()
            policy.endPlayback(owner: "nonexistent")
            try expect(!policy.isMuted && policy.activeOwners == ["work"], "Unrelated cleanup must not mute live playback")
        }

        try check("Volume changes while opted out cannot preauthorize re-enabling") {
            var policy = playingSpeaker()
            policy.setEnabled(false)
            policy.volumeChanged(from: 0.2, to: 0.8, routeID: "speaker", at: 10)
            policy.setEnabled(true)
            try expect(policy.isMuted, "Opted-out volume changes must not become an allowance")
        }

        try check("Re-enabling guard rejects queued volume changes from before opt-in") {
            var policy = playingSpeaker()
            policy.setEnabled(false)
            policy.setEnabled(true)
            // The service establishes a new automatic-change window on opt-in.
            policy.ignoreAutomaticVolumeChanges(at: 20)
            policy.volumeChanged(from: 0.2, to: 0.8, routeID: "speaker", at: 19)
            policy.volumeChanged(from: 0.8, to: 0.7, routeID: "speaker", at: 20.74)
            try expect(policy.isMuted, "Opt-in must not be undone by a queued old volume action")
            policy.volumeChanged(from: 0.7, to: 0.6, routeID: "speaker", at: 20.75)
            try expect(!policy.isMuted, "New volume intent after the opt-in window should work")
        }

        print("Speaker protection checks: \(passed) passed, 0 failed")
    }
}
