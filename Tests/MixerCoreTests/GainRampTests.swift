import Testing
@testable import MixerCore

@Suite struct GainRampTests {
    @Test func convergesToTargetWithinRampTime() {
        var ramp = GainRamp(initial: 1, rampTime: 0.03, sampleRate: 48_000)
        let frames = Int(0.03 * 48_000)
        var last: Float = 1
        for _ in 0..<frames { last = ramp.step(target: 0.2) }
        // 95% of the way: 1 -> 0.2 is a 0.8 drop, so <= 0.2 + 0.04.
        #expect(last <= 0.24)
        #expect(last >= 0.2)
    }

    @Test func settlesExactlyAndStaysStable() {
        var ramp = GainRamp(initial: 0, rampTime: 0.01, sampleRate: 48_000)
        for _ in 0..<48_000 { _ = ramp.step(target: 0.5) }
        #expect(ramp.current == 0.5)
        for _ in 0..<100 { #expect(ramp.step(target: 0.5) == 0.5) }
    }

    @Test func isMonotonicWhileRamping() {
        var ramp = GainRamp(initial: 1, rampTime: 0.03, sampleRate: 48_000)
        var prev: Float = 1
        for _ in 0..<2_000 {
            let g = ramp.step(target: 0)
            #expect(g <= prev)
            prev = g
        }
    }

    @Test func clampsTargets() {
        var ramp = GainRamp(initial: 0.5)
        for _ in 0..<100_000 { _ = ramp.step(target: 7) }
        #expect(ramp.current == 1)
        for _ in 0..<100_000 { _ = ramp.step(target: -3) }
        #expect(ramp.current == 0)
    }

    @Test func resetJumpsImmediately() {
        var ramp = GainRamp(initial: 1)
        ramp.reset(to: 0.3)
        #expect(ramp.current == 0.3)
    }

    @Test func interleavedApplyUsesSameGainAcrossChannels() {
        var ramp = GainRamp(initial: 0.5, rampTime: 0.03, sampleRate: 48_000)
        let frames = 64, channels = 2
        let input = [Float](repeating: 1, count: frames * channels)
        var output = [Float](repeating: 0, count: frames * channels)
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                ramp.applyInterleaved(target: 0.5, input: inp.baseAddress!, output: out.baseAddress!,
                                      channels: channels, frames: frames)
            }
        }
        for f in 0..<frames {
            #expect(output[f * 2] == output[f * 2 + 1])
            #expect(output[f * 2] == 0.5)
        }
    }

    @Test func degenerateParametersYieldInstantRamp() {
        #expect(GainRamp.coefficient(rampTime: 0, sampleRate: 48_000) == 1)
        #expect(GainRamp.coefficient(rampTime: 0.03, sampleRate: 0) == 1)
    }
}
