import Foundation

/// Per-app user setting. `volume` is linear 0...1 as shown on the slider.
public struct AppAudioSettings: Codable, Equatable, Sendable {
    public var volume: Float
    public var isMuted: Bool

    public static let passthrough = AppAudioSettings(volume: 1, isMuted: false)

    public init(volume: Float, isMuted: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }

    /// True when the app needs no tap at all: full volume and not muted.
    public var isPassthrough: Bool { volume >= 1 && !isMuted }

    /// Linear gain to apply on the tapped path. Mute wins.
    public var effectiveGain: Float { isMuted ? 0 : volume }
}

/// Where per-app settings live. Keyed by the group key (bundle id or the
/// synthetic WebKit key).
public protocol SettingsStore: Sendable {
    func load(_ key: String) -> AppAudioSettings?
    func save(_ settings: AppAudioSettings, for key: String)
    func remove(_ key: String)
    /// Every key with a saved non-passthrough setting.
    func allKeys() -> [String]
}

/// In-memory store for tests and previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AppAudioSettings] = [:]
    public init() {}
    public func load(_ key: String) -> AppAudioSettings? { lock.withLock { values[key] } }
    public func save(_ settings: AppAudioSettings, for key: String) {
        lock.withLock { values[key] = settings }
    }
    public func remove(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
    public func allKeys() -> [String] { lock.withLock { Array(values.keys) } }
}

/// UserDefaults-backed store. Passthrough settings are removed rather than
/// stored, so `allKeys()` only ever lists apps the user actually adjusted.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let rootKey: String

    public init(defaults: UserDefaults = .standard, rootKey: String = "appSettings") {
        self.defaults = defaults
        self.rootKey = rootKey
    }

    private func readAll() -> [String: AppAudioSettings] {
        guard let data = defaults.data(forKey: rootKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AppAudioSettings].self, from: data)) ?? [:]
    }

    private func writeAll(_ all: [String: AppAudioSettings]) {
        if all.isEmpty {
            defaults.removeObject(forKey: rootKey)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: rootKey)
        }
    }

    public func load(_ key: String) -> AppAudioSettings? { readAll()[key] }

    public func save(_ settings: AppAudioSettings, for key: String) {
        var all = readAll()
        if settings.isPassthrough {
            all.removeValue(forKey: key)
        } else {
            all[key] = settings
        }
        writeAll(all)
    }

    public func remove(_ key: String) {
        var all = readAll()
        all.removeValue(forKey: key)
        writeAll(all)
    }

    public func allKeys() -> [String] { Array(readAll().keys) }
}
