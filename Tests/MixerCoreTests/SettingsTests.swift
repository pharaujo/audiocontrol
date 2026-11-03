import Foundation
import Testing
@testable import MixerCore

@Suite struct SettingsTests {
    @Test func passthroughDetection() {
        #expect(AppAudioSettings(volume: 1, isMuted: false).isPassthrough)
        #expect(!AppAudioSettings(volume: 0.99, isMuted: false).isPassthrough)
        #expect(!AppAudioSettings(volume: 1, isMuted: true).isPassthrough)
    }

    @Test func effectiveGainMuteWins() {
        #expect(AppAudioSettings(volume: 0.7, isMuted: true).effectiveGain == 0)
        #expect(AppAudioSettings(volume: 0.7, isMuted: false).effectiveGain == 0.7)
    }

    @Test func volumeIsClamped() {
        #expect(AppAudioSettings(volume: 3, isMuted: false).volume == 1)
        #expect(AppAudioSettings(volume: -1, isMuted: false).volume == 0)
    }

    @Test func userDefaultsRoundTripAndPassthroughRemoval() {
        let suite = "MixerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        store.save(AppAudioSettings(volume: 0.3, isMuted: false), for: "com.example.a")
        store.save(AppAudioSettings(volume: 1, isMuted: true), for: "com.example.b")
        #expect(store.load("com.example.a") == AppAudioSettings(volume: 0.3, isMuted: false))
        #expect(Set(store.allKeys()) == ["com.example.a", "com.example.b"])

        store.save(.passthrough, for: "com.example.a")
        #expect(store.load("com.example.a") == nil)
        #expect(store.allKeys() == ["com.example.b"])

        store.remove("com.example.b")
        #expect(store.allKeys().isEmpty)
    }
}
