import Testing
@testable import MixerCore

@Suite struct PermissionGateTests {
    private func granted() -> PermissionGate {
        var g = PermissionGate()
        _ = g.apply(result: .granted, trigger: .launch, generation: g.generation)
        #expect(g.state == .granted)
        return g
    }

    private func effects(_ o: PermissionGate.Outcome) -> PermissionGate.Effects {
        if case .applied(let fx) = o { return fx }
        Issue.record("expected .applied, got .dropped")
        return .none
    }

    @Test func launchGrantedAndDenied() {
        var g = PermissionGate()
        let fx = effects(g.apply(result: .granted, trigger: .launch, generation: 0))
        #expect(g.state == .granted && g.allowsChannels)
        #expect(fx.setGrantConfirmed && fx.clearStarvedFlags && !fx.lifted && !fx.clearGrantConfirmed)

        var d = PermissionGate()
        let dfx = effects(d.apply(result: .denied, trigger: .launch, generation: 0))
        #expect(d.state == .denied && !d.allowsChannels)
        #expect(dfx.clearGrantConfirmed && !dfx.setGrantConfirmed)
    }

    @Test func notDeterminedRequestsPromptOnlyForLaunchOrUser() {
        var g = PermissionGate()
        #expect(effects(g.apply(result: .notDetermined, trigger: .launch, generation: 0)).requestPrompt)
        #expect(effects(g.apply(result: .notDetermined, trigger: .userInitiated, generation: 0)).requestPrompt)
        #expect(!effects(g.apply(result: .notDetermined, trigger: .popoverOpen, generation: 0)).requestPrompt)
        #expect(g.state == .unknown)
    }

    @Test func inconclusiveHasNoEffects() {
        var g = granted()
        let o = g.apply(result: .inconclusive, trigger: .popoverOpen, generation: g.generation)
        #expect(o == .applied(.none))
        #expect(g.state == .granted)
    }

    @Test func releaseFromGrantedThenAutomaticGrantedStaysReleasedAndMarksChecked() {
        var g = granted()
        g.release()
        #expect(g.state == .released && g.releasedFrom == .granted && !g.allowsChannels)
        let fx = effects(g.apply(result: .granted, trigger: .popoverOpen, generation: g.generation))
        #expect(g.state == .released)
        #expect(g.releaseChecked)
        #expect(!fx.lifted)
    }

    @Test func automaticDeniedWhileReleasedSetsOriginToDenied() {
        var g = granted()
        g.release()
        let fx = effects(g.apply(result: .denied, trigger: .popoverOpen, generation: g.generation))
        #expect(g.state == .released && g.releasedFrom == .denied)
        #expect(fx.clearGrantConfirmed)
    }

    @Test func automaticGrantedLiftsDeniedOriginRelease() {
        var g = granted()
        g.release()
        _ = g.apply(result: .denied, trigger: .popoverOpen, generation: g.generation)
        let before = g.generation
        let fx = effects(g.apply(result: .granted, trigger: .popoverOpen, generation: g.generation))
        #expect(fx.lifted && g.state == .granted && g.releasedFrom == nil && !g.releaseChecked)
        #expect(g.generation == before + 1)
    }

    @Test func userInitiatedGrantedLiftsGrantedOriginRelease() {
        var g = granted()
        g.release()
        let fx = effects(g.apply(result: .granted, trigger: .userInitiated, generation: g.generation))
        #expect(fx.lifted && g.state == .granted)
    }

    @Test func releaseFromAssumedCountsAsDenied() {
        var g = PermissionGate()
        g.assumeGranted()
        #expect(g.state == .assumed && g.allowsChannels)
        g.release()
        #expect(g.releasedFrom == .denied)
    }

    @Test func releaseFromDeniedCountsAsDenied() {
        var g = PermissionGate()
        _ = g.apply(result: .denied, trigger: .launch, generation: 0)
        g.release()
        #expect(g.releasedFrom == .denied)
    }

    @Test func pressBumpsGenerationAndResetsChecked() {
        var g = granted()
        g.release()
        _ = g.apply(result: .granted, trigger: .popoverOpen, generation: g.generation)
        #expect(g.releaseChecked)
        _ = g.apply(result: .granted, trigger: .userInitiated, generation: g.generation) // lift
        #expect(!g.releaseChecked && g.releasedFrom == nil)
        let gen = g.generation
        g.release()
        #expect(g.generation == gen + 1)
        #expect(!g.releaseChecked && g.releasedFrom == .granted)
    }

    @Test func staleResultIsDroppedWithNoChanges() {
        var g = granted()
        let stale = g.generation
        g.release()
        let snapshot = g
        #expect(g.apply(result: .granted, trigger: .userInitiated, generation: stale) == .dropped)
        #expect(g == snapshot)
        #expect(g.apply(result: .denied, trigger: .starvation, generation: stale) == .dropped)
        #expect(g == snapshot)
    }

    @Test func starvationTriggerConsumesEpisode() {
        var g = granted()
        #expect(effects(g.apply(result: .granted, trigger: .starvation, generation: g.generation)).consumeProbeEpisode)
        #expect(effects(g.apply(result: .denied, trigger: .starvation, generation: g.generation)).consumeProbeEpisode)
        #expect(!effects(g.apply(result: .granted, trigger: .popoverOpen, generation: g.generation)).consumeProbeEpisode)
    }

    @Test func popoverOpenRules() {
        var g = PermissionGate()
        #expect(g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
        #expect(!g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: true, isSPI: false))

        _ = g.apply(result: .granted, trigger: .launch, generation: 0)
        #expect(!g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
        #expect(g.shouldCheckOnPopoverOpen(anyUnprobedStarved: true, longProbeRunning: false, isSPI: false))

        g.release() // from granted
        #expect(g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
        _ = g.apply(result: .granted, trigger: .popoverOpen, generation: g.generation) // checked
        #expect(!g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
        #expect(g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: true))

        _ = g.apply(result: .denied, trigger: .userInitiated, generation: g.generation) // origin -> denied
        #expect(g.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))

        var d = PermissionGate()
        _ = d.apply(result: .denied, trigger: .launch, generation: 0)
        #expect(d.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
        var a = PermissionGate(); a.assumeGranted()
        #expect(a.shouldCheckOnPopoverOpen(anyUnprobedStarved: false, longProbeRunning: false, isSPI: false))
    }
}
