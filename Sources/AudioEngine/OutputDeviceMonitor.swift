import CoreAudio
import Foundation

/// Tracks the system default output device and reports changes on the main actor.
@MainActor
public final class OutputDeviceMonitor {
    public struct Device: Equatable, Sendable {
        public let id: AudioObjectID
        public let uid: String
        public let name: String
        public let isBluetooth: Bool
    }

    public private(set) var current: Device?
    public var onChange: ((Device?) -> Void)?

    private var listener: CA.Listener?
    private var devicesListener: CA.Listener?

    public init() {
        current = Self.readDefault()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        listener = CA.Listener(sys, .init(kAudioHardwarePropertyDefaultOutputDevice), queue: .main) {
            MainActor.assumeIsolated { OutputDeviceMonitorRegistry.shared.notifyAll() }
        }
        devicesListener = CA.Listener(sys, .init(kAudioHardwarePropertyDevices), queue: .main) {
            MainActor.assumeIsolated { OutputDeviceMonitorRegistry.shared.notifyAll() }
        }
        OutputDeviceMonitorRegistry.shared.register(self)
    }

    fileprivate func refresh() {
        let new = Self.readDefault()
        if new != current {
            Log.device.info("default output changed: \(new?.name ?? "none", privacy: .public) [\(new?.uid ?? "-", privacy: .public)]")
            current = new
            onChange?(new)
        }
    }

    static func readDefault() -> Device? {
        guard let id = CA.defaultOutputDeviceID(), let uid = CA.deviceUID(id) else { return nil }
        return Device(id: id, uid: uid, name: CA.objectName(id) ?? "Output", isBluetooth: CA.isBluetooth(id))
    }

    /// Is this device ID still present on the system?
    public static func deviceExists(_ id: AudioObjectID) -> Bool {
        CA.allDeviceIDs().contains(id)
    }
}

/// Listener blocks must not capture the monitor strongly (it would never
/// deinit), so a tiny weak registry fans notifications out instead.
@MainActor
final class OutputDeviceMonitorRegistry {
    static let shared = OutputDeviceMonitorRegistry()
    private var monitors = NSHashTable<OutputDeviceMonitor>.weakObjects()
    func register(_ m: OutputDeviceMonitor) { monitors.add(m) }
    func notifyAll() { for m in monitors.allObjects { m.refresh() } }
}
