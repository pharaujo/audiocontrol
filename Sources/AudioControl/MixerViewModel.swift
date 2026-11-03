import AppKit
import AudioEngine
import MixerCore
import Observation
import SwiftUI

@MainActor
@Observable
final class MixerViewModel {
    struct AppRow: Identifiable, Equatable {
        let key: String
        let name: String
        let icon: NSImage?
        var volume: Float
        var isMuted: Bool
        var isPlaying: Bool
        var isWebKit: Bool
        var isLive: Bool
        var isStarved: Bool
        var routingFailed: Bool
        var id: String { key }
    }

    private(set) var rows: [AppRow] = []
    private(set) var outputName: String = "Output"
    private(set) var masterVolume: Float? = nil
    private(set) var masterMuted: Bool? = nil
    private(set) var canSetMasterVolume = false
    private(set) var canSetMasterMute = false

    private let discovery = ProcessDiscovery()
    private let output = OutputDeviceMonitor()
    private var master: MasterVolumeController?
    private let store: SettingsStore = UserDefaultsSettingsStore()
    private let engine: MixerEngine
    private let permission: PermissionManager
    private var observers: [NSObjectProtocol] = []
    private var lastPopoverOpen: Date = .distantPast
    private(set) var liveChannelCount = 0
    private(set) var permissionState: PermissionState = .unknown
    private(set) var permissionUsesSPI = true

    var showsPermissionBanner: Bool { !permissionState.allowsChannels }
    var permissionBannerText: String {
        switch permissionState {
        case .unknown: return "AudioControl needs System Audio Recording permission to adjust app volumes."
        case .denied: return "System Audio Recording is off for AudioControl. Per-app volume is disabled; apps play at full volume."
        case .released: return "All taps released. Apps play at full volume until permission is re-checked."
        case .granted, .assumed: return ""
        }
    }
    var permissionBannerButton: String {
        switch permissionState {
        case .unknown: return "Grant Permission"
        default: return "Open System Settings"
        }
    }
    private var lastSeenPlaying: [String: Date] = [:]
    private var lingerTimer: Timer?
    private var iconCache: [String: NSImage] = [:]
    static let linger: TimeInterval = 30

    init() {
        engine = MixerEngine(store: store)
        permission = PermissionManager(engine: engine)
        permissionUsesSPI = permission.usesSPI
        permission.onChange = { [weak self] in self?.permissionChanged() }
        engine.onStatusChange = { [weak self] in self?.rebuildRows() }
        discovery.onChange = { [weak self] apps in
            self?.engine.appsChanged(apps)
            self?.rebuildRows()
        }
        output.onChange = { [weak self] dev in
            self?.engine.outputChanged(dev)
            self?.outputChanged(dev)
        }
        engine.outputChanged(output.current)
        outputChanged(output.current)
        engine.appsChanged(discovery.apps)
        rebuildRows()
        permission.checkAtLaunch()
        permissionChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logStatusItemPlacement() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.shutdown() }
        })
        // Popover-open detection: the MenuBarExtra panel becomes key / visible.
        // `onAppear` is not trusted (window-style content may stay alive).
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Delivered on the main queue; Notification itself is not Sendable,
                // so pull the window out first and only touch it inside the hop.
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    // The status item itself is a ~22pt NSWindow; only the popover panel is wide.
                    guard let self, let w = window, w.isVisible, w.occlusionState.contains(.visible),
                          w.frame.width >= 200 else { return }
                    self.popoverOpened()
                }
            })
        }
    }

    /// Diagnostic: where did the system put our status item?
    private func logStatusItemPlacement() {
        for w in NSApp.windows {
            let cls = String(describing: type(of: w))
            guard cls.contains("StatusBar") || w.frame.height <= 40 else { continue }
            let screen = w.screen.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) safeTop=\(Int($0.safeAreaInsets.top))" } ?? "none"
            Log.ui.info("status window \(cls, privacy: .public) frame=\(NSStringFromRect(w.frame), privacy: .public) visible=\(w.isVisible) onActiveSpace=\(w.isOnActiveSpace) occluded=\(!w.occlusionState.contains(.visible)) screen=\(screen, privacy: .public)")
        }
    }

    private func popoverOpened() {
        let now = Date()
        guard now.timeIntervalSince(lastPopoverOpen) > 0.3 else { return }
        lastPopoverOpen = now
        Log.ui.debug("popover opened")
        permission.popoverOpened()
    }

    private func permissionChanged() {
        permissionState = permission.state
        rebuildRows()
    }

    func permissionBannerAction() { permission.bannerAction() }
    func checkPermissionAgain() { permission.checkAgain() }
    func releaseAllTaps() { permission.releaseAllTaps() }

    private func outputChanged(_ dev: OutputDeviceMonitor.Device?) {
        outputName = dev?.name ?? "No output"
        if let dev {
            if let m = master { m.retarget(dev.id) } else {
                master = MasterVolumeController(deviceID: dev.id)
                master?.onChange = { [weak self] in self?.readMaster() }
            }
        } else {
            master = nil
        }
        readMaster()
    }

    private func readMaster() {
        masterVolume = master?.volume
        masterMuted = master?.isMuted
        canSetMasterVolume = master?.canSetVolume ?? false
        canSetMasterMute = master?.canSetMute ?? false
    }

    func setMasterVolume(_ v: Float) { master?.setVolume(v); readMaster() }
    func setMasterMuted(_ m: Bool) { master?.setMuted(m); readMaster() }

    private func rebuildRows() {
        let now = Date()
        var out: [AppRow] = []
        var needLinger = false
        for app in discovery.apps {
            if app.isRunningOutput { lastSeenPlaying[app.key] = now }
            let saved = store.load(app.key)
            let status = engine.status(for: app.key)
            let recentlyPlayed = (lastSeenPlaying[app.key].map { now.timeIntervalSince($0) < Self.linger }) ?? false
            if !app.isRunningOutput && !recentlyPlayed && saved == nil { continue }
            if !app.isRunningOutput && recentlyPlayed { needLinger = true }
            out.append(AppRow(key: app.key, name: app.name, icon: icon(for: app),
                              volume: saved?.volume ?? 1, isMuted: saved?.isMuted ?? false,
                              isPlaying: app.isRunningOutput, isWebKit: app.isWebKitGroup,
                              isLive: status.isLive, isStarved: status.isStarved, routingFailed: status.routingFailed))
        }
        rows = out
        liveChannelCount = engine.liveChannelCount
        lingerTimer?.invalidate()
        if needLinger {
            lingerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.rebuildRows() }
            }
        }
    }

    private func icon(for app: AudioApp) -> NSImage? {
        if let c = iconCache[app.key] { return c }
        var img: NSImage?
        if let url = app.bundleURL { img = NSWorkspace.shared.icon(forFile: url.path) }
        if img == nil, let pid = app.pids.first, let r = NSRunningApplication(processIdentifier: pid) { img = r.icon }
        if let img { img.size = NSSize(width: 20, height: 20); iconCache[app.key] = img }
        return img
    }

    func setVolume(_ v: Float, for key: String) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        rows[i].volume = v
        engine.setSettings(AppAudioSettings(volume: v, isMuted: rows[i].isMuted), for: key)
    }

    func setMuted(_ m: Bool, for key: String) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        rows[i].isMuted = m
        engine.setSettings(AppAudioSettings(volume: rows[i].volume, isMuted: m), for: key)
    }
}
