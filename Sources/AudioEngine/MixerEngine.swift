import CoreAudio
import Foundation
import MixerCore

/// Owns one tap channel per adjusted app and reconciles desired state to live
/// channels. One structural operation per group at a time; gain changes never
/// wait; retries never block the task.
@MainActor
public final class MixerEngine {
    public struct DesiredState: Equatable, Sendable {
        public var settings: AppAudioSettings
        public var processObjectIDs: [AudioObjectID]
        public var output: OutputDeviceMonitor.Device?
        public var displayName: String

        /// Changes that require a channel to be (re)built or torn down.
        func structurallyDiffers(from other: DesiredState) -> Bool {
            processObjectIDs != other.processObjectIDs
                || output?.uid != other.output?.uid
                || settings.isPassthrough != other.settings.isPassthrough
        }
    }

    public struct GroupStatus: Equatable, Sendable {
        public var isLive: Bool
        public var isStarved: Bool
        public var routingFailed: Bool
    }

    final class Group {
        var desired: DesiredState
        var current: ProcessTapChannel?
        var building: ProcessTapChannel?
        var running: Task<Void, Never>?
        var dirty = false
        var retry: Task<Void, Never>?
        var pendingRetryDelay: Duration?
        var failures = 0
        var exhausted = false
        var starved = false
        var probedThisEpisode = false
        var forceRebuild = false
        var stalledSince: ContinuousClock.Instant?
        var lastCallbacks: UInt64 = 0
        init(desired: DesiredState) { self.desired = desired }
    }

    public static let maxFailures = 5
    public static let starvationSeconds: Double = 10
    /// How long to keep the old channel alive while the new one spins up, when the app is playing.
    public static let firstCallbackGrace: Duration = .seconds(1)
    /// A playing app whose live channel never calls back for this long is stalled; rebuild it.
    public static let stallSeconds: Double = 10

    private var groups: [String: Group] = [:]
    private let store: SettingsStore
    private var output: OutputDeviceMonitor.Device?
    private var apps: [String: AudioApp] = [:]
    private var starvationTimer: Timer?

    /// Gate: when false, every group resolves to "no channel".
    public var permissionAllowed = false {
        didSet { if oldValue != permissionAllowed { reconcileAll() } }
    }
    /// Fired when live/starved/failed status changes (UI refresh).
    public var onStatusChange: (() -> Void)?
    /// Fired when a channel newly enters starvation and has not been checked this episode.
    public var onStarvation: ((String) -> Void)?

    public init(store: SettingsStore) {
        self.store = store
        starvationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStarvation() }
        }
    }

    // MARK: Inputs

    public func outputChanged(_ dev: OutputDeviceMonitor.Device?) {
        output = dev
        for (key, g) in groups {
            var d = g.desired
            d.output = dev
            update(key, to: d)
        }
    }

    public func appsChanged(_ list: [AudioApp]) {
        apps = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
        // Existing groups: update membership (or empty it when the app vanished).
        for (key, g) in groups {
            var d = g.desired
            d.processObjectIDs = apps[key]?.processObjectIDs ?? []
            if let n = apps[key]?.name { d.displayName = n }
            update(key, to: d)
        }
        // New apps with a saved non-passthrough setting get a group right away.
        for app in list where groups[app.key] == nil {
            if let saved = store.load(app.key), !saved.isPassthrough {
                let d = DesiredState(settings: saved, processObjectIDs: app.processObjectIDs,
                                     output: output, displayName: app.name)
                groups[app.key] = Group(desired: d)
                reconcile(app.key)
            }
        }
        pruneIdleGroups()
    }

    public func settings(for key: String) -> AppAudioSettings {
        groups[key]?.desired.settings ?? store.load(key) ?? .passthrough
    }

    /// Slider/mute. Writes the gain immediately; only passthrough-boundary
    /// crossings are structural.
    public func setSettings(_ s: AppAudioSettings, for key: String) {
        store.save(s, for: key)
        guard let app = apps[key] ?? groups[key].map({ g in
            AudioApp(key: key, name: g.desired.displayName, bundleURL: nil,
                     processObjectIDs: g.desired.processObjectIDs, pids: [], isRunningOutput: false) })
        else { return }
        if let g = groups[key] {
            var d = g.desired
            d.settings = s
            update(key, to: d)
        } else if !s.isPassthrough {
            let d = DesiredState(settings: s, processObjectIDs: app.processObjectIDs,
                                 output: output, displayName: app.name)
            groups[key] = Group(desired: d)
            reconcile(key)
        }
    }

    public func status(for key: String) -> GroupStatus {
        guard let g = groups[key] else { return GroupStatus(isLive: false, isStarved: false, routingFailed: false) }
        return GroupStatus(isLive: g.current != nil, isStarved: g.starved, routingFailed: g.exhausted)
    }

    public var liveChannelCount: Int { groups.values.filter { $0.current != nil }.count }
    public var anyUnprobedStarved: Bool { groups.values.contains { $0.starved && !$0.probedThisEpisode } }

    /// Permission-gate effects.
    public func clearStarvedFlags() {
        var changed = false
        for g in groups.values where g.starved { g.starved = false; changed = true }
        if changed { onStatusChange?() }
    }
    public func markProbedThisEpisode() {
        for g in groups.values where g.starved { g.probedThisEpisode = true }
    }

    /// Quit: bypass the loop, destroy everything, including in-flight channels.
    public func shutdown() {
        starvationTimer?.invalidate()
        for g in groups.values {
            g.running?.cancel(); g.retry?.cancel()
            g.building?.destroy(); g.building = nil
            g.current?.destroy(); g.current = nil
        }
        ChannelRegistry.shared.destroyAll()
        Log.engine.info("engine shut down")
    }

    // MARK: Desired-state plumbing

    private func update(_ key: String, to d: DesiredState) {
        guard let g = groups[key] else { return }
        let old = g.desired
        g.desired = d
        // Gain never waits.
        let gain = d.settings.effectiveGain
        g.current?.setTargetGain(gain)
        g.building?.setTargetGain(gain)
        if d.structurallyDiffers(from: old) {
            g.failures = 0
            g.exhausted = false
            g.retry?.cancel(); g.retry = nil
            reconcile(key)
        }
    }

    private func reconcileAll() { for key in groups.keys { reconcile(key) } }

    /// Drop groups that are passthrough, idle, and not tracked by discovery.
    private func pruneIdleGroups() {
        for (key, g) in groups where g.current == nil && g.building == nil && g.running == nil
            && g.desired.settings.isPassthrough && apps[key] == nil {
            g.retry?.cancel()
            groups.removeValue(forKey: key)
        }
    }

    // MARK: Reconcile loop

    public func reconcile(_ key: String) {
        guard let g = groups[key] else { return }
        if g.running != nil { g.dirty = true; return }
        g.retry?.cancel(); g.retry = nil
        g.running = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                g.dirty = false
                await self.perform(g, key: key)
            } while g.dirty && !Task.isCancelled
            g.running = nil
            if let delay = g.pendingRetryDelay, !g.exhausted {
                g.pendingRetryDelay = nil
                g.retry = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.reconcile(key)
                }
            }
            self.onStatusChange?()
        }
    }

    private func perform(_ g: Group, key: String) async {
        let d = g.desired
        let want = permissionAllowed && !d.settings.isPassthrough && !d.processObjectIDs.isEmpty && d.output != nil

        if !want {
            if let c = g.current { c.destroy(); g.current = nil; Log.engine.info("\(key, privacy: .public): passthrough") }
            g.starved = false
            g.failures = 0
            g.exhausted = false
            return
        }
        guard let out = d.output else { return }

        if let cur = g.current, cur.processObjectIDs == d.processObjectIDs, cur.outputDeviceUID == out.uid, !g.forceRebuild {
            cur.setTargetGain(d.settings.effectiveGain)
            return
        }
        if g.exhausted { return }

        // Build new first, then destroy old, so a muted app never bursts. The new
        // tap mutes the process's direct path as soon as it exists; the new
        // aggregate's IO only starts once a tapped process produces audio, so
        // "no callback yet" is normal for an idle app and is not a failure.
        let new = ProcessTapChannel(key: key, displayName: d.displayName, processObjectIDs: d.processObjectIDs,
                                    outputDeviceID: out.id, outputDeviceUID: out.uid,
                                    initialGain: d.settings.effectiveGain)
        g.building = new
        defer { if g.building === new { g.building = nil } }
        do {
            try await new.start()
            let t0 = ContinuousClock.now
            if apps[key]?.isRunningOutput ?? false {
                // App is playing: keep the old channel rendering until the new
                // one runs (bounded), so the switch gap stays tens of ms.
                let deadline = t0 + Self.firstCallbackGrace
                while !new.hasCalledBack, ContinuousClock.now < deadline {
                    if let old = g.current, !OutputDeviceMonitor.deviceExists(old.outputDeviceID) {
                        Log.engine.info("\(key, privacy: .public): old device gone, destroying old channel early")
                        old.destroy(); g.current = nil
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let old = g.current
            g.current = new
            g.building = nil
            g.forceRebuild = false
            old?.destroy()
            g.failures = 0
            g.starved = false
            g.stalledSince = nil
            g.probedThisEpisode = false
            let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
            Log.engine.info("\(key, privacy: .public): channel live on \(out.name, privacy: .public) gain=\(d.settings.effectiveGain) \(new.hasCalledBack ? "firstCallbackAfter=\(ms)ms" : "idle (no IO until the app plays)", privacy: .public)")
        } catch {
            new.destroy()
            g.building = nil
            g.failures += 1
            Log.engine.error("\(key, privacy: .public): channel start failed (\(g.failures)/\(Self.maxFailures)): \(String(describing: error), privacy: .public)")
            if let old = g.current, !OutputDeviceMonitor.deviceExists(old.outputDeviceID) {
                old.destroy(); g.current = nil
            }
            if g.failures >= Self.maxFailures {
                g.exhausted = true
                g.current?.destroy(); g.current = nil
                Log.engine.error("\(key, privacy: .public): giving up; app plays at full volume until a structural change")
            } else {
                let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]
                g.pendingRetryDelay = backoff[min(g.failures - 1, backoff.count - 1)]
            }
        }
    }

    // MARK: Starvation

    private var pollTicks = 0
    private func pollStarvation() {
        var changed = false
        pollTicks += 1
        for (key, g) in groups {
            if pollTicks % 5 == 0, let c = g.current {
                Log.engine.debug("\(key, privacy: .public): callbacks=\(c.callbacks) audio=\(c.hasSeenAudio) silent=\(c.silentSeconds, format: .fixed(precision: 1))s gain=\(c.currentTargetGain)")
            }
            guard let c = g.current else {
                if g.starved { g.starved = false; changed = true }
                continue
            }
            let producing = apps[key]?.isRunningOutput ?? false
            let gainOn = g.desired.settings.effectiveGain > 0

            // Stall: the app is producing but our IO never runs (or stopped running).
            let cb = c.callbacks
            if producing, cb == g.lastCallbacks {
                let since = g.stalledSince ?? ContinuousClock.now
                g.stalledSince = since
                if (ContinuousClock.now - since) >= .seconds(Self.stallSeconds), g.running == nil {
                    g.failures += 1
                    Log.engine.error("\(key, privacy: .public): IO stalled for \(Self.stallSeconds)s while producing (\(g.failures)/\(Self.maxFailures)); rebuilding")
                    g.stalledSince = nil
                    if g.failures >= Self.maxFailures {
                        g.exhausted = true
                        c.destroy(); g.current = nil
                        changed = true
                        continue
                    }
                    g.forceRebuild = true
                    reconcile(key)
                    continue
                }
            } else {
                g.stalledSince = nil
            }
            g.lastCallbacks = cb
            let starvedNow = producing && gainOn && c.hasCalledBack && c.silentSeconds >= Self.starvationSeconds
            if c.silentSeconds == 0 || !c.hasCalledBack {
                // Non-zero input arrived (or nothing yet): episode over.
                if g.starved { g.starved = false; changed = true }
                g.probedThisEpisode = false
            } else if starvedNow, !g.starved {
                g.starved = true
                changed = true
                Log.engine.notice("\(key, privacy: .public): starved (\(c.silentSeconds, format: .fixed(precision: 1)) s of silence while producing)")
                if !g.probedThisEpisode { onStarvation?(key) }
            }
        }
        if changed { onStatusChange?() }
    }
}
