import AudioToolbox
import CoreAudio
import Foundation
import MixerCore
import Synchronization

/// One process tap + one private aggregate device + one IOProc that re-renders
/// the tapped audio to the real output device with gain applied.
///
/// Lifecycle is driven from the main actor (`start()` / `destroy()`); the IO
/// block runs on Core Audio's real-time thread and touches only the atomics
/// and the preallocated `rt` state. `destroy()` is idempotent.
public final class ProcessTapChannel: @unchecked Sendable {
    public let key: String
    public let displayName: String
    public let processObjectIDs: [AudioObjectID]
    public let outputDeviceID: AudioObjectID
    public let outputDeviceUID: String
    public let muteBehavior: CATapMuteBehavior

    public private(set) var tapID: AudioObjectID = kAudioObjectUnknown
    public private(set) var aggregateID: AudioObjectID = kAudioObjectUnknown
    public private(set) var sampleRate: Double = 48_000
    public private(set) var inputChannels: Int = 0
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private var destroyed = false
    private let tapUUID = UUID()

    private let rt: RTState

    /// State shared with / owned by the IO thread. The atomics are written
    /// from the main actor and read on the IO thread (or vice versa); the ramp
    /// and gain buffer are IO-thread-only once started. Allocated up front so
    /// the callback never allocates.
    private final class RTState: @unchecked Sendable {
        let targetGain: Atomic<Float>
        let callbackCount = Atomic<UInt64>(0)
        let nonZeroCallbacks = Atomic<UInt64>(0)
        /// Consecutive input frames that were all zero (reset on any non-zero sample).
        let silentFrames = Atomic<UInt64>(0)
        var ramp: GainRamp
        let gainBuffer: UnsafeMutablePointer<Float>
        let gainCapacity: Int
        init(initialGain: Float, sampleRate: Double, maxFrames: Int) {
            targetGain = Atomic(initialGain)
            ramp = GainRamp(initial: initialGain, rampTime: 0.03, sampleRate: sampleRate)
            gainCapacity = maxFrames
            gainBuffer = .allocate(capacity: maxFrames)
            gainBuffer.initialize(repeating: initialGain, count: maxFrames)
        }
        deinit { gainBuffer.deallocate() }
    }

    public init(key: String, displayName: String, processObjectIDs: [AudioObjectID],
                outputDeviceID: AudioObjectID, outputDeviceUID: String,
                initialGain: Float, muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        self.key = key
        self.displayName = displayName
        self.processObjectIDs = processObjectIDs
        self.outputDeviceID = outputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.muteBehavior = muteBehavior
        rt = RTState(initialGain: min(max(initialGain, 0), 1), sampleRate: 48_000, maxFrames: 16_384)
        ChannelRegistry.shared.add(self)
    }

    deinit { destroy() }

    // MARK: Control

    /// Set the target gain. Safe from any thread; the IO thread ramps to it.
    public func setTargetGain(_ g: Float) {
        rt.targetGain.store(min(max(g, 0), 1), ordering: .relaxed)
    }
    public var currentTargetGain: Float { rt.targetGain.load(ordering: .relaxed) }

    /// True once the IO block has run at least once.
    public var hasCalledBack: Bool { rt.callbackCount.load(ordering: .relaxed) > 0 }
    public var callbacks: UInt64 { rt.callbackCount.load(ordering: .relaxed) }
    /// True once any non-zero input sample has been seen.
    public var hasSeenAudio: Bool { rt.nonZeroCallbacks.load(ordering: .relaxed) > 0 }
    /// Seconds of consecutive all-zero input, as of now.
    public var silentSeconds: Double { Double(rt.silentFrames.load(ordering: .relaxed)) / sampleRate }

    // MARK: Lifecycle

    public enum StartError: Error, CustomStringConvertible {
        case coreAudio(CoreAudioError)
        case notReady
        case alreadyDestroyed
        public var description: String {
            switch self {
            case .coreAudio(let e): return e.description
            case .notReady: return "aggregate device never became ready"
            case .alreadyDestroyed: return "channel already destroyed"
            }
        }
    }

    /// Create the tap, the aggregate, and the IOProc, then start IO. Polls
    /// briefly for the aggregate to expose its streams before starting.
    @MainActor
    public func start() async throws {
        guard !destroyed else { throw StartError.alreadyDestroyed }
        guard !started else { return }

        // 1. Tap.
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = tapUUID
        desc.muteBehavior = muteBehavior
        desc.isPrivate = true
        desc.name = "AudioControl: \(displayName)"
        var tap = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else {
            throw StartError.coreAudio(CoreAudioError(status: st, what: "AudioHardwareCreateProcessTap"))
        }
        tapID = tap

        // 2. Aggregate: real output as main sub-device, tap as input.
        let aggUID = "com.pedroaraujo.audiocontrol.agg.\(tapUUID.uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioControl \(displayName)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let st2 = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st2 == noErr, agg != kAudioObjectUnknown else {
            destroy()
            throw StartError.coreAudio(CoreAudioError(status: st2, what: "AudioHardwareCreateAggregateDevice"))
        }
        aggregateID = agg

        // 3. Wait for streams on both sides (prior art: starting too early fails silently).
        var ready = false
        for _ in 0..<50 { // up to ~1 s
            if CA.streamCount(agg, scope: kAudioObjectPropertyScopeInput) > 0,
               CA.streamCount(agg, scope: kAudioObjectPropertyScopeOutput) > 0 { ready = true; break }
            try? await Task.sleep(for: .milliseconds(20))
            if destroyed { throw StartError.alreadyDestroyed }
        }
        guard ready else { destroy(); throw StartError.notReady }

        // 4. Format for the ramp's sample rate and channel count.
        if let fmt = try? CA.get(tap, .init(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self) {
            sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : (CA.nominalSampleRate(agg) ?? 48_000)
            inputChannels = Int(fmt.mChannelsPerFrame)
        } else {
            sampleRate = CA.nominalSampleRate(agg) ?? 48_000
        }
        rt.ramp = GainRamp(initial: currentTargetGain, rampTime: 0.03, sampleRate: sampleRate)

        // 5. IOProc.
        let rt = self.rt
        var proc: AudioDeviceIOProcID?
        // `@Sendable` is load-bearing: without it the closure inherits this
        // method's @MainActor isolation and Swift 6 inserts a runtime executor
        // check that traps on Core Audio's IO thread.
        let block: AudioDeviceIOBlock = { @Sendable _, inInput, _, outOutput, _ in
            ProcessTapChannel.render(input: inInput, output: outOutput, rt: rt)
        }
        let st3 = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, block)
        guard st3 == noErr, let proc else {
            destroy()
            throw StartError.coreAudio(CoreAudioError(status: st3, what: "AudioDeviceCreateIOProcIDWithBlock"))
        }
        procID = proc
        let st4 = AudioDeviceStart(agg, proc)
        guard st4 == noErr else {
            destroy()
            throw StartError.coreAudio(CoreAudioError(status: st4, what: "AudioDeviceStart"))
        }
        started = true
        Log.tap.info("channel \(self.key, privacy: .public) started: tap=\(tap) agg=\(agg) sr=\(self.sampleRate) ch=\(self.inputChannels) gain=\(self.currentTargetGain)")
    }

    /// Stop IO and release everything. Safe to call repeatedly and from deinit.
    public func destroy() {
        if destroyed { return }
        destroyed = true
        if aggregateID != kAudioObjectUnknown, let proc = procID {
            if started { AudioDeviceStop(aggregateID, proc) }
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        started = false
        ChannelRegistry.shared.remove(self)
        Log.tap.info("channel \(self.key, privacy: .public) destroyed")
    }

    public var isDestroyed: Bool { destroyed }

    // MARK: Real-time render

    /// Copies tap input to device output, channel i -> channel i, applying the
    /// ramped gain per frame. Extra output channels are zeroed. No allocation,
    /// no locks, no ObjC, no logging.
    @inline(__always)
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               rt: RTState) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let target = rt.targetGain.load(ordering: .relaxed)

        // Frame count from the first output buffer (Float32 assumed: HAL
        // aggregate streams are always Float32 on the client side).
        var frames = 0
        if outList.count > 0 {
            let b = outList[0]
            if b.mNumberChannels > 0 { frames = Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)) }
        }
        if frames > rt.gainCapacity { frames = rt.gainCapacity }

        // Per-frame gain curve, shared by all channels.
        var f = 0
        while f < frames { rt.gainBuffer[f] = rt.ramp.step(target: target); f += 1 }

        // Zero everything first (cheap, and handles unmatched channels).
        for ob in outList {
            if let p = ob.mData { memset(p, 0, Int(ob.mDataByteSize)) }
        }

        var anyNonZeroBits: UInt32 = 0
        var globalIn = 0      // running input channel index
        var inBuf = 0         // which input buffer we're in
        var inChInBuf = 0     // channel within that buffer
        var globalOut = 0
        for ob in outList {
            guard let outRaw = ob.mData else { globalOut += Int(ob.mNumberChannels); continue }
            let outCh = Int(ob.mNumberChannels)
            let outPtr = outRaw.assumingMemoryBound(to: Float.self)
            let outFrames = min(frames, Int(ob.mDataByteSize) / max(1, 4 * outCh))
            var c = 0
            while c < outCh {
                // Advance input cursor to globalOut (channel i -> i).
                while inBuf < inList.count, globalIn < globalOut {
                    globalIn += 1; inChInBuf += 1
                    if inChInBuf >= Int(inList[inBuf].mNumberChannels) { inBuf += 1; inChInBuf = 0 }
                }
                if inBuf < inList.count, globalIn == globalOut, let inRaw = inList[inBuf].mData {
                    let ib = inList[inBuf]
                    let inCh = Int(ib.mNumberChannels)
                    let inPtr = inRaw.assumingMemoryBound(to: Float.self)
                    let inFrames = min(outFrames, Int(ib.mDataByteSize) / max(1, 4 * inCh))
                    var i = 0
                    while i < inFrames {
                        let s = inPtr[i * inCh + inChInBuf]
                        anyNonZeroBits |= s.bitPattern & 0x7fff_ffff
                        outPtr[i * outCh + c] = s * rt.gainBuffer[i]
                        i += 1
                    }
                }
                c += 1
                globalOut += 1
            }
        }

        rt.callbackCount.wrappingAdd(1, ordering: .relaxed)
        if anyNonZeroBits != 0 {
            rt.nonZeroCallbacks.wrappingAdd(1, ordering: .relaxed)
            rt.silentFrames.store(0, ordering: .relaxed)
        } else {
            rt.silentFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
        }
    }
}

/// Weak set of every channel ever started, so `applicationWillTerminate` can
/// destroy in-flight ones too. Weak, so deinit still runs.
final class ChannelRegistry: @unchecked Sendable {
    static let shared = ChannelRegistry()
    private let lock = NSLock()
    private let table = NSHashTable<ProcessTapChannel>.weakObjects()
    func add(_ c: ProcessTapChannel) { lock.withLock { table.add(c) } }
    func remove(_ c: ProcessTapChannel) { lock.withLock { table.remove(c) } }
    var all: [ProcessTapChannel] { lock.withLock { table.allObjects } }
    func destroyAll() { for c in all { c.destroy() } }
}
