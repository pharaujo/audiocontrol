import Foundation

/// One-pole smoother that glides the applied gain toward a target so gain
/// changes never click. Pure value type, safe to keep in a heap box owned by
/// a real-time IO thread: `step`/`apply` do no allocation, locking, or I/O.
public struct GainRamp: Sendable {
    /// Gain currently applied (linear, 0...1).
    public private(set) var current: Float
    /// Per-sample smoothing coefficient in (0, 1].
    public let coefficient: Float

    /// - Parameters:
    ///   - initial: starting gain.
    ///   - rampTime: time (seconds) to travel ~95% of the way to a new target.
    ///   - sampleRate: frames per second the ramp is stepped at.
    public init(initial: Float = 1, rampTime: Double = 0.03, sampleRate: Double = 48_000) {
        current = GainRamp.clamp(initial)
        coefficient = GainRamp.coefficient(rampTime: rampTime, sampleRate: sampleRate)
    }

    /// 95% settling in `rampTime` means three time constants: tau = rampTime / 3.
    public static func coefficient(rampTime: Double, sampleRate: Double) -> Float {
        guard rampTime > 0, sampleRate > 0 else { return 1 }
        let tau = rampTime / 3
        let k = 1 - exp(-1 / (tau * sampleRate))
        return Float(min(max(k, 1e-6), 1))
    }

    @inline(__always)
    static func clamp(_ g: Float) -> Float { min(max(g, 0), 1) }

    /// Advance one frame toward `target` and return the gain to apply.
    @inline(__always)
    public mutating func step(target: Float) -> Float {
        let t = GainRamp.clamp(target)
        let delta = t - current
        // Snap when within -80 dBFS of the target so we settle exactly instead of
        // stalling on Float32 resolution (delta * coefficient can drop below ulp).
        if abs(delta) < 1e-4 {
            current = t
        } else {
            current += delta * coefficient
        }
        return current
    }

    /// Jump straight to `target` without ramping (used when a channel starts).
    public mutating func reset(to target: Float) {
        current = GainRamp.clamp(target)
    }

    /// Multiply `frames` interleaved-or-planar samples of one channel by the
    /// ramped gain. For multi-channel audio call once per frame with `step`
    /// instead; this helper is for the single-channel / planar case.
    @inline(__always)
    public mutating func apply(target: Float,
                               input: UnsafePointer<Float>,
                               output: UnsafeMutablePointer<Float>,
                               frames: Int) {
        var i = 0
        while i < frames {
            output[i] = input[i] * step(target: target)
            i += 1
        }
    }

    /// Planar multi-channel apply: the same per-frame gain is used for every
    /// channel so stereo image is preserved. `inputs[c]`/`outputs[c]` are the
    /// channel buffers; `channels` may be 0 (then nothing happens).
    @inline(__always)
    public mutating func apply(target: Float,
                               inputs: UnsafeBufferPointer<UnsafePointer<Float>>,
                               outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
                               channels: Int,
                               frames: Int) {
        var f = 0
        while f < frames {
            let g = step(target: target)
            var c = 0
            while c < channels {
                outputs[c][f] = inputs[c][f] * g
                c += 1
            }
            f += 1
        }
    }

    /// Interleaved multi-channel apply.
    @inline(__always)
    public mutating func applyInterleaved(target: Float,
                                          input: UnsafePointer<Float>,
                                          output: UnsafeMutablePointer<Float>,
                                          channels: Int,
                                          frames: Int) {
        var f = 0
        var idx = 0
        while f < frames {
            let g = step(target: target)
            var c = 0
            while c < channels {
                output[idx] = input[idx] * g
                idx += 1
                c += 1
            }
            f += 1
        }
    }
}
