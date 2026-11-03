import AppKit
import CoreAudio
import Darwin
import Foundation

/// A group of audio-producing processes that belong to one app.
public struct AudioApp: Identifiable, Equatable, Sendable {
    /// Group key: the owning app's bundle id, or `webKitKey` for the shared
    /// WebKit XPC processes. Used for settings persistence.
    public let key: String
    public let name: String
    public let bundleURL: URL?
    public let processObjectIDs: [AudioObjectID]
    public let pids: [pid_t]
    public let isRunningOutput: Bool
    public var id: String { key }

    public static let webKitKey = "com.apple.WebKit"
    public static let webKitName = "Web Content (Safari & WebKit apps)"
    public var isWebKitGroup: Bool { key == AudioApp.webKitKey }
}

/// Enumerates Core Audio process objects, groups helpers under their owning
/// app, and republishes on every change. Event-driven: no polling.
@MainActor
public final class ProcessDiscovery {
    public private(set) var apps: [AudioApp] = []
    /// Called after `apps` changes (added, removed, or isRunningOutput flipped).
    public var onChange: (([AudioApp]) -> Void)?

    private var listListener: CA.Listener?
    private var processListeners: [AudioObjectID: [CA.Listener]] = [:]
    private var rescanScheduled = false
    private let ownPID = getpid()
    private var ownerCache: [pid_t: Owner] = [:]

    struct Owner: Equatable {
        let key: String
        let name: String
        let bundleURL: URL?
    }

    public init() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        listListener = CA.Listener(sys, .init(kAudioHardwarePropertyProcessObjectList), queue: .main) {
            MainActor.assumeIsolated { ProcessDiscoveryRegistry.shared.scheduleAll() }
        }
        ProcessDiscoveryRegistry.shared.register(self)
        rescan()
    }

    /// Coalesce bursts of notifications into one scan per run-loop turn.
    fileprivate func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            self.rescan()
        }
    }

    public func rescan() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let objects = (try? CA.getArray(sys, .init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []

        // Maintain per-process IsRunningOutput listeners.
        let live = Set(objects)
        for (id, _) in processListeners where !live.contains(id) { processListeners.removeValue(forKey: id) }
        for id in objects where processListeners[id] == nil {
            // Verified on macOS 27: a listener on IsRunningOutput registers fine but
            // is never called, although the value changes. IsRunning does fire on
            // every start/stop, and the rescan then reads IsRunningOutput. Keep both
            // in case a future macOS starts delivering IsRunningOutput.
            let selectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]
            processListeners[id] = selectors.compactMap { sel in
                CA.Listener(id, .init(sel), queue: .main) {
                    MainActor.assumeIsolated { ProcessDiscoveryRegistry.shared.scheduleAll() }
                }
            }
        }

        struct Row { let object: AudioObjectID; let pid: pid_t; let running: Bool; let owner: Owner }
        var rows: [Row] = []
        var livePIDs = Set<pid_t>()
        for obj in objects {
            guard let pid = try? CA.get(obj, .init(kAudioProcessPropertyPID), as: pid_t.self), pid > 0 else { continue }
            if pid == ownPID { continue }
            livePIDs.insert(pid)
            let running = ((try? CA.get(obj, .init(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0) != 0
            let bundleID = (try? CA.getString(obj, .init(kAudioProcessPropertyBundleID))) ?? ""
            let owner: Owner
            if let cached = ownerCache[pid] {
                owner = cached
            } else {
                owner = resolveOwner(pid: pid, bundleID: bundleID)
                ownerCache[pid] = owner
            }
            rows.append(Row(object: obj, pid: pid, running: running, owner: owner))
        }
        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }

        var grouped: [String: (owner: Owner, objs: [AudioObjectID], pids: [pid_t], running: Bool)] = [:]
        for r in rows {
            var g = grouped[r.owner.key] ?? (r.owner, [], [], false)
            g.objs.append(r.object)
            g.pids.append(r.pid)
            g.running = g.running || r.running
            grouped[r.owner.key] = g
        }
        let newApps = grouped.values.map {
            AudioApp(key: $0.owner.key, name: $0.owner.name, bundleURL: $0.owner.bundleURL,
                     processObjectIDs: $0.objs.sorted(), pids: $0.pids.sorted(), isRunningOutput: $0.running)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        Log.discovery.info("rescan: \(objects.count) process objects, \(newApps.count) groups")
        if newApps != apps {
            apps = newApps
            Log.discovery.info("apps: \(newApps.map { "\($0.name)[\($0.pids.count)p \($0.isRunningOutput ? "▶" : "■")]" }.joined(separator: ", "), privacy: .public)")
            onChange?(newApps)
        }
    }

    // MARK: Owner resolution

    /// Friendlier names for system daemons that play audio.
    static let friendlyNames: [String: String] = [
        "systemsoundserverd": "System Sounds",
        "com.apple.systemsoundserverd": "System Sounds",
        "com.apple.assistantd": "Siri",
        "PowerChime": "Power Chime",
        "com.apple.PowerChime": "Power Chime",
        "com.apple.mediaremoted": "Media Remote",
        "com.apple.avconferenced": "FaceTime Audio",
        "com.apple.CoreSpeech": "Speech",
        "com.apple.accessibility.heard": "Accessibility",
        "callservicesd": "Phone Calls",
        "com.apple.speech.speechsynthesisd": "Speech Synthesis",
    ]

    private func resolveOwner(pid: pid_t, bundleID: String) -> Owner {
        let o = resolveOwnerUncached(pid: pid, bundleID: bundleID)
        if let friendly = Self.friendlyNames[o.key] ?? Self.friendlyNames[o.name] {
            return Owner(key: o.key, name: friendly, bundleURL: o.bundleURL)
        }
        return o
    }

    private func resolveOwnerUncached(pid: pid_t, bundleID: String) -> Owner {
        // Shared WebKit XPC services: parent is launchd, attribution impossible
        // without private API. One honest synthetic group.
        if bundleID.hasPrefix("com.apple.WebKit.") {
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            return Owner(key: AudioApp.webKitKey, name: AudioApp.webKitName, bundleURL: safari)
        }
        // Walk up until we find a regular (Dock-visible) app.
        var cursor = pid
        var hops = 0
        while cursor > 1, hops < 16 {
            if let app = NSRunningApplication(processIdentifier: cursor),
               app.activationPolicy == .regular, let bid = app.bundleIdentifier {
                return Owner(key: bid, name: app.localizedName ?? bid, bundleURL: app.bundleURL)
            }
            guard let parent = Self.parentPID(of: cursor), parent != cursor else { break }
            cursor = parent
            hops += 1
        }
        // Accessory/background app with a bundle (menu bar apps, agents).
        if let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
            return Owner(key: bid, name: app.localizedName ?? bid, bundleURL: app.bundleURL)
        }
        if !bundleID.isEmpty {
            return Owner(key: bundleID, name: bundleID, bundleURL: nil)
        }
        let comm = Self.processName(of: pid) ?? "pid \(pid)"
        return Owner(key: "proc:\(comm)", name: comm, bundleURL: nil)
    }

    static func kinfo(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        return info
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        kinfo(of: pid)?.kp_eproc.e_ppid
    }

    static func processName(of pid: pid_t) -> String? {
        guard var info = kinfo(of: pid) else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }
}

@MainActor
final class ProcessDiscoveryRegistry {
    static let shared = ProcessDiscoveryRegistry()
    private var instances = NSHashTable<ProcessDiscovery>.weakObjects()
    func register(_ d: ProcessDiscovery) { instances.add(d) }
    func scheduleAll() { for d in instances.allObjects { d.scheduleRescan() } }
}
