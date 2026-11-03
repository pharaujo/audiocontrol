import AppKit
import Foundation
import MixerCore

/// Drives the `PermissionGate` from TCC preflight results and applies the
/// gate's effects to the engine and to persisted flags. The engine's flags are
/// mutated only here, through `Effects`.
@MainActor
public final class PermissionManager {
    public private(set) var gate = PermissionGate()
    public var state: PermissionState { gate.state }
    public var allowsChannels: Bool { gate.allowsChannels }
    public let usesSPI: Bool
    public var onChange: (() -> Void)?

    private let engine: MixerEngine
    private let tcc = TCCAccess.shared
    private let defaults: UserDefaults
    private let identity = CodeIdentity.current
    private var grantConfirmedKey: String { "grantConfirmed.\(identity.flagSuffix)" }
    private var requestInFlight = false

    public init(engine: MixerEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        usesSPI = tcc.available
        engine.onStarvation = { [weak self] key in
            Log.permission.notice("starvation on \(key, privacy: .public): re-checking permission")
            self?.check(trigger: .starvation)
        }
        Log.permission.info("code identity: \(self.identity.identifier, privacy: .public) adhoc=\(self.identity.isAdHoc) leaf=\(self.identity.leafHash, privacy: .public) spi=\(self.usesSPI)")
    }

    public var grantConfirmed: Bool { defaults.bool(forKey: grantConfirmedKey) }

    // MARK: Triggers

    public func checkAtLaunch() { check(trigger: .launch) }

    public func popoverOpened() {
        guard gate.shouldCheckOnPopoverOpen(anyUnprobedStarved: engine.anyUnprobedStarved,
                                            longProbeRunning: false, isSPI: usesSPI) else { return }
        check(trigger: .popoverOpen)
    }

    public func checkAgain() { check(trigger: .userInitiated) }

    /// Banner button: preflight at click time. notDetermined → system prompt;
    /// denied → System Settings pane; granted → user-initiated check (lifts).
    public func bannerAction() {
        switch tcc.preflight() {
        case .notDetermined:
            requestPrompt(trigger: .userInitiated)
        case .denied, .unavailable:
            openSystemSettings()
        case .granted:
            check(trigger: .userInitiated)
        }
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Release all taps": sticky until a check lifts it per the gate rules.
    public func releaseAllTaps() {
        gate.release()
        Log.permission.notice("release all taps (from \(String(describing: self.gate.releasedFrom), privacy: .public))")
        push()
    }

    // MARK: Checking

    private func check(trigger: CheckTrigger) {
        let stamp = gate.generation
        let result: CheckResult
        switch tcc.preflight() {
        case .granted: result = .granted
        case .denied: result = .denied
        case .notDetermined: result = .notDetermined
        case .unavailable: result = .inconclusive
        }
        apply(result: result, trigger: trigger, stamp: stamp)
    }

    private func apply(result: CheckResult, trigger: CheckTrigger, stamp: UInt64) {
        let outcome = gate.apply(result: result, trigger: trigger, generation: stamp)
        switch outcome {
        case .dropped:
            Log.permission.info("check result \(String(describing: result), privacy: .public) from \(String(describing: trigger), privacy: .public) dropped (stale generation \(stamp) != \(self.gate.generation))")
            return
        case .applied(let fx):
            Log.permission.info("check \(String(describing: trigger), privacy: .public) → \(String(describing: result), privacy: .public); state=\(String(describing: self.gate.state), privacy: .public) releasedFrom=\(String(describing: self.gate.releasedFrom), privacy: .public) lifted=\(fx.lifted)")
            applyEffects(fx, trigger: trigger)
        }
        push()
    }

    private func applyEffects(_ fx: PermissionGate.Effects, trigger: CheckTrigger) {
        if fx.setGrantConfirmed, !identity.isAdHoc { defaults.set(true, forKey: grantConfirmedKey) }
        if fx.clearGrantConfirmed { defaults.removeObject(forKey: grantConfirmedKey) }
        if fx.clearStarvedFlags { engine.clearStarvedFlags() }
        if fx.consumeProbeEpisode { engine.markProbedThisEpisode() }
        if fx.requestPrompt { requestPrompt(trigger: trigger) }
    }

    private func requestPrompt(trigger: CheckTrigger) {
        guard !requestInFlight else { return }
        requestInFlight = true
        Log.permission.info("requesting System Audio Recording prompt")
        tcc.request { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.requestInFlight = false
                Log.permission.info("prompt answered: granted=\(granted)")
                self.check(trigger: trigger)
            }
        }
    }

    private func push() {
        engine.permissionAllowed = gate.allowsChannels
        onChange?()
    }
}
