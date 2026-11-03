import SwiftUI

@main
struct AudioControlApp: App {
    // `@State` is a macro whose plugin ships only with Xcode (not Command Line Tools);
    // the App value is created once, so a plain stored property is equivalent here.
    private let model = MixerViewModel()

    var body: some Scene {
        MenuBarExtra("AudioControl", systemImage: "speaker.wave.2.fill") {
            MixerView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
