import Foundation

/// Gate state for the System Audio Recording permission.
public enum PermissionState: Equatable, Sendable {
    /// No check has produced a verdict yet.
    case unknown
    /// A check saw the grant.
    case granted
    /// Launch probe skipped (Bluetooth output, earlier grant confirmed); gates like `.granted`.
    case assumed
    /// A check saw the grant missing.
    case denied
    /// User pressed "Release all taps"; gates like `.denied` until lifted.
    case released

    /// Whether `.mutedWhenTapped` channels may exist in this state.
    public var allowsChannels: Bool { self == .granted || self == .assumed }
}

/// What a check (probe or TCC preflight) concluded.
public enum CheckResult: Equatable, Sendable {
    case granted
    case denied
    /// The check could not conclude (e.g. probe IO never started). No effects.
    case inconclusive
    /// TCC has never asked (preflight 2). Only the SPI path produces this.
    case notDetermined
}

/// Who asked for the check. Automatic triggers must never lift a release the
/// user made while the grant was fine; user-initiated ones always may.
public enum CheckTrigger: Equatable, Sendable {
    case launch
    case popoverOpen
    case starvation
    case userInitiated
    public var isUserInitiated: Bool { self == .userInitiated }
}

/// Pure state machine. The engine owns the real flags (`grantConfirmed`,
/// starved channels, probe episodes) and is only allowed to touch them
/// through the `Effects` this returns, so a stale result can never leak.
public struct PermissionGate: Equatable, Sendable {
    public struct Effects: Equatable, Sendable {
        public var setGrantConfirmed = false
        public var clearGrantConfirmed = false
        public var clearStarvedFlags = false
        public var consumeProbeEpisode = false
        public var lifted = false
        public var requestPrompt = false
        public static let none = Effects()
        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        /// Result was stamped with an older generation; nothing happened.
        case dropped
        case applied(Effects)
    }

    public private(set) var state: PermissionState = .unknown
    /// State in force when "Release all taps" was pressed, normalised to
    /// `.granted` or `.denied`. `nil` unless `state == .released`.
    public private(set) var releasedFrom: PermissionState?
    /// Probe path only: one automatic check has passed since a granted-origin
    /// release, so no further automatic probes (tones) should run.
    public private(set) var releaseChecked = false
    /// Bumped on every press and every lift. Checks stamp the value current
    /// when they start; older stamps are dropped.
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Whether the engine may create `.mutedWhenTapped` channels.
    public var allowsChannels: Bool { state.allowsChannels }

    /// Bluetooth skip at launch. Only valid from `.unknown`.
    public mutating func assumeGranted() {
        guard state == .unknown else { return }
        state = .assumed
    }

    /// "Release all taps". Sticky until lifted.
    public mutating func release() {
        releasedFrom = (state == .granted) ? .granted : .denied
        state = .released
        releaseChecked = false
        generation &+= 1
    }

    /// Should an automatic check run on popover open?
    /// - Parameters:
    ///   - anyUnprobedStarved: a live channel is starved and not yet checked in its episode.
    ///   - longProbeRunning: the first-launch long probe is still in flight.
    ///   - isSPI: TCC preflight is in use (free), rather than the tone probe.
    public func shouldCheckOnPopoverOpen(anyUnprobedStarved: Bool,
                                         longProbeRunning: Bool,
                                         isSPI: Bool) -> Bool {
        if longProbeRunning { return false }
        switch state {
        case .unknown, .denied, .assumed:
            return true
        case .granted:
            return anyUnprobedStarved
        case .released:
            if releasedFrom == .denied { return true }
            return isSPI ? true : !releaseChecked
        }
    }

    /// Apply a check result. `generation` must be the value read when the
    /// check started.
    public mutating func apply(result: CheckResult,
                               trigger: CheckTrigger,
                               generation stamp: UInt64) -> Outcome {
        guard stamp == generation else { return .dropped }
        var fx = Effects()

        switch result {
        case .inconclusive:
            return .applied(fx)

        case .notDetermined:
            // TCC never asked. Prompt on launch or user action; nothing else changes.
            if trigger == .launch || trigger.isUserInitiated { fx.requestPrompt = true }
            if state == .assumed { state = .unknown }
            return .applied(fx)

        case .granted:
            fx.setGrantConfirmed = true
            fx.clearStarvedFlags = true
            if trigger == .starvation { fx.consumeProbeEpisode = true }
            if state == .released {
                if trigger.isUserInitiated || releasedFrom == .denied {
                    lift(&fx)
                } else {
                    releaseChecked = true
                }
            } else {
                state = .granted
            }
            return .applied(fx)

        case .denied:
            fx.clearGrantConfirmed = true
            if trigger == .starvation { fx.consumeProbeEpisode = true }
            if state == .released {
                releasedFrom = .denied
            } else {
                state = .denied
            }
            return .applied(fx)
        }
    }

    private mutating func lift(_ fx: inout Effects) {
        state = .granted
        releasedFrom = nil
        releaseChecked = false
        generation &+= 1
        fx.lifted = true
    }
}
