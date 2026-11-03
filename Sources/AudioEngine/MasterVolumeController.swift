import CoreAudio
import Foundation

/// Volume/mute of one output device. Uses the main element when the device
/// has one; otherwise averages/sets channels 1 and 2. `volume == nil` means
/// the device exposes no volume control (HDMI/DisplayPort, some USB).
@MainActor
public final class MasterVolumeController {
    public private(set) var deviceID: AudioObjectID
    public private(set) var volume: Float?
    public private(set) var isMuted: Bool?
    public var onChange: (() -> Void)?

    private var listeners: [CA.Listener] = []
    private let scope = kAudioObjectPropertyScopeOutput
    private var volumeElements: [AudioObjectPropertyElement] = []
    private var muteElement: AudioObjectPropertyElement?

    public init(deviceID: AudioObjectID) {
        self.deviceID = deviceID
        configure()
    }

    public func retarget(_ id: AudioObjectID) {
        deviceID = id
        listeners.removeAll()
        configure()
    }

    private func configure() {
        volumeElements = []
        muteElement = nil
        let main = kAudioObjectPropertyElementMain
        if CA.has(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: main)),
           CA.isSettable(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: main)) {
            volumeElements = [main]
        } else {
            for ch: AudioObjectPropertyElement in [1, 2] where
                CA.has(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)) &&
                CA.isSettable(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)) {
                volumeElements.append(ch)
            }
        }
        for el in [main, 1, 2] as [AudioObjectPropertyElement] where
            CA.has(deviceID, .init(kAudioDevicePropertyMute, scope: scope, element: el)) {
            muteElement = el
            break
        }
        // Listen on every element we use.
        var addrs = volumeElements.map { AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0) }
        if let m = muteElement { addrs.append(.init(kAudioDevicePropertyMute, scope: scope, element: m)) }
        let dev = deviceID
        listeners = addrs.compactMap { addr in
            CA.Listener(dev, addr, queue: .main) {
                MainActor.assumeIsolated { MasterVolumeRegistry.shared.notify(device: dev) }
            }
        }
        MasterVolumeRegistry.shared.register(self)
        read()
    }

    fileprivate func read() {
        let oldV = volume, oldM = isMuted
        if volumeElements.isEmpty {
            volume = nil
        } else {
            let values = volumeElements.compactMap {
                try? CA.get(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0), as: Float32.self)
            }
            volume = values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
        }
        if let m = muteElement {
            isMuted = ((try? CA.get(deviceID, .init(kAudioDevicePropertyMute, scope: scope, element: m), as: UInt32.self)) ?? 0) != 0
        } else {
            isMuted = nil
        }
        if oldV != volume || oldM != isMuted { onChange?() }
    }

    public var canSetVolume: Bool { !volumeElements.isEmpty }
    public var canSetMute: Bool { muteElement != nil && CA.isSettable(deviceID, .init(kAudioDevicePropertyMute, scope: scope, element: muteElement!)) }

    public func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        for el in volumeElements {
            try? CA.set(deviceID, .init(kAudioDevicePropertyVolumeScalar, scope: scope, element: el), Float32(clamped))
        }
        volume = canSetVolume ? clamped : nil
    }

    public func setMuted(_ m: Bool) {
        guard let el = muteElement else { return }
        try? CA.set(deviceID, .init(kAudioDevicePropertyMute, scope: scope, element: el), UInt32(m ? 1 : 0))
        isMuted = m
    }
}

@MainActor
final class MasterVolumeRegistry {
    static let shared = MasterVolumeRegistry()
    private var controllers = NSHashTable<MasterVolumeController>.weakObjects()
    func register(_ c: MasterVolumeController) { controllers.add(c) }
    func notify(device: AudioObjectID) {
        for c in controllers.allObjects where c.deviceID == device { c.read() }
    }
}
