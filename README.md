# AudioControl

Per-app volume and mute for macOS, in the menu bar. Pure Swift, SwiftPM, no
Xcode project, no drivers, no kernel extensions. Built for personal use.

macOS has no API to set another process's gain. AudioControl uses the only
driver-free route: a **Core Audio process tap** on the app with
`muteBehavior = .mutedWhenTapped`, which silences the app's direct path, and a
private aggregate device whose IOProc re-renders the tapped audio to the real
output device with gain applied. Apps left at 100% are never tapped and pay no
latency; adjusted apps gain roughly 10–20 ms.

## Requirements

- macOS 15 or later (developed and tested on macOS 27.0.1).
- Swift 6 toolchain. Command Line Tools are enough; Xcode is not needed.
- Apple silicon or Intel (the build script builds for the host).

## Build

```sh
# One-time: self-signed code-signing identity so the System Audio Recording
# grant survives rebuilds (ad-hoc signatures change on every build).
scripts/make-signing-cert.sh

# Build, assemble build/AudioControl.app, sign.
scripts/build-app.sh
open build/AudioControl.app
```

`scripts/build-app.sh` signs with the SHA-1 of the identity whose common name
is exactly `AudioControl Dev` (override with `SIGN_IDENTITY=...`). If no such
identity exists it falls back to ad-hoc signing with a warning. Never run the
bare `swift run` binary for anything involving taps: it has no
`NSAudioCaptureUsageDescription` and inherits the terminal's TCC attribution.

Logs:

```sh
log stream --predicate 'subsystem == "com.pedroaraujo.audiocontrol"' --level debug
```

Unit tests (pure-Swift core: gain ramp, settings, permission state machine):

```sh
swift test
```

## Permission

Taps need **System Audio Recording** (Privacy & Security). On first launch
AudioControl asks for it; until it is granted, no app is tapped and everything
plays at full volume. The failure mode is always "full volume", never "silent".

Permission state is read through the private TCC SPI (`TCCAccessPreflight`
/ `TCCAccessRequest`, loaded with `dlsym`), the same approach as
insidegui/AudioCap. Personal-use trade-off: a future macOS could remove it.
Verified on macOS 27.0.1: preflight returns *granted* after the user allows,
and the system prompt appears on request for an undetermined state. The
in-process *revoke* transition still needs a manual check (see Verification).

## How it works

```
Sources/MixerCore      pure Swift, unit-tested: GainRamp, AppAudioSettings, PermissionGate
Sources/AudioEngine    Core Audio: ProcessDiscovery, ProcessTapChannel, MixerEngine,
                       OutputDeviceMonitor, MasterVolumeController, TCCAccess, PermissionManager
Sources/AudioControl   SwiftUI MenuBarExtra shell and view model
```

- **Discovery** reads `kAudioHardwarePropertyProcessObjectList` and groups
  helper processes (Chrome, Electron, Teams, Slack, ...) under their owning
  app by walking parent PIDs to the first regular app. Safari and every other
  WebKit app share XPC processes whose parent is launchd, so they appear as one
  honest row, "Web Content (Safari & WebKit apps)".
- **Channels** exist only for apps adjusted below 100% or muted. Settings are
  remembered per bundle id and re-applied when the app appears.
- **Reconcile loop**: one structural operation per app at a time; slider and
  mute writes go straight to the live channel's atomic gain and never wait.
  Replacement (device change, helper membership change) builds the new tap
  before destroying the old one so a muted app never bursts.
- **Master volume** uses the default output device's volume/mute properties.

## Known limitations

- Adjusted apps get ~10–20 ms extra latency and a short gap when a tap engages or releases.
- A brand-new helper process in an adjusted app plays directly at full volume for the
  ~50–200 ms until the tap includes it. Core Audio cannot mute a process before it
  reports it. Chrome is unaffected in practice (one audio-service helper).
- Safari and all WebKit apps share one setting.
- A grant revoked mid-session leaves tapped apps silent for up to ~10 s, until the
  starvation check re-reads TCC and drops every app to passthrough (or macOS
  terminates AudioControl, which also restores audio).
- Devices in hog mode cannot join an aggregate; the slider will fail for those.
- The self-signed certificate buys permission persistence only, not Gatekeeper trust.

## Findings worth knowing (from building this)

- An aggregate device whose only input is a process tap does **not** run IO
  until a tapped process produces audio. "No callback yet" is normal for an
  idle app, not a failure; the tap exists (and mutes the process) regardless.
- A property listener on `kAudioProcessPropertyIsRunningOutput` registers without
  error but is never called on macOS 27, although the value changes. Listen on
  `kAudioProcessPropertyIsRunning` instead (it fires on every start and stop) and
  read `IsRunningOutput` in the handler.
- The completion block passed to `TCCAccessRequest` must be declared `@escaping`
  in the function-pointer type; TCC calls it later and a non-escaping block traps.
- The IOProc block must be `@Sendable`. Otherwise, in Swift 6, it inherits the
  creating method's `@MainActor` isolation and traps on Core Audio's IO thread.
- SwiftUI's `@State` macro plugin ships only with Xcode. With Command Line
  Tools, hold the model as a plain stored property on the `App` struct.
- `AudioHardwareCreateProcessTap` blocks while the TCC prompt is on screen;
  gating on preflight first avoids freezing the UI.

## Verification still owed by a human ear / hand

1. Play audio in Music and Chrome, drag Chrome to 30%: Chrome quieter, Music
   unchanged, no click. Mute/unmute. Back to 100%: short gap, tap released.
2. Revoke System Audio Recording in System Settings **while AudioControl runs**
   with an app tapped: within ~10 s the row shows the orange glyph, the app
   returns to full volume and the banner appears. Re-grant and open the popover:
   the setting re-applies. If instead nothing happens until a relaunch, TCC
   caches preflight per process; see the plan's probe fallback.
3. Switch output devices (headphones, AirPods) with an app tapped: audio continues
   at the same gain; a muted app stays silent throughout.
