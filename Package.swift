// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioControl",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure Swift: DSP, models, policies. No CoreAudio, no AppKit. Unit-tested.
        .target(
            name: "MixerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Core Audio HAL layer: devices, processes, taps, permission.
        .target(
            name: "AudioEngine",
            dependencies: ["MixerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
        // The menu bar app.
        .executableTarget(
            name: "AudioControl",
            dependencies: ["AudioEngine", "MixerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MixerCoreTests",
            dependencies: ["MixerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
