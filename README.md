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
and the system prompt appears on request for an undetermined state.

**Changes in System Settings apply only after AudioControl restarts.** macOS
says so when you toggle the switch ("…until it is quit"), and it holds in both
directions: turning the permission off leaves a running AudioControl able to
capture, and turning it on leaves a running, denied AudioControl denied
(preflight keeps returning *denied*). The banner therefore offers
**Relaunch AudioControl** instead of a re-check.

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
- **Pause all adjustments** (footer, shown while any app is adjusted) removes
  every tap so all apps play at full volume, and keeps your saved settings.
  App rows are greyed out while paused; **Resume** in the banner re-applies them.

## Known limitations

- Adjusted apps get ~10–20 ms extra latency and a short gap when a tap engages or releases.
- A brand-new helper process in an adjusted app plays directly at full volume for the
  ~50–200 ms until the tap includes it. Core Audio cannot mute a process before it
  reports it. Chrome is unaffected in practice (one audio-service helper).
- Safari and all WebKit apps share one setting.
- Turning System Audio Recording off in System Settings does not stop a running
  AudioControl; adjustments keep working until it quits. Turning it on needs a
  relaunch (banner button). The starvation check (orange glyph after ~10 s of
  silence from an app that reports playing) stays as a safety net for paths that
  bypass System Settings, such as `tccutil reset`.
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
- SwiftPM 6.4 with Command Line Tools stamps the binary with the deployment
  target as its SDK version (`sdk 15.0`), which makes AppKit use the pre-macOS 26
  compatibility look. `scripts/build-app.sh` rewrites the stamp with `vtool`
  before signing; check with `otool -l <binary> | grep -A4 LC_BUILD_VERSION`.
- SwiftUI's `@State` macro plugin ships only with Xcode. With Command Line
  Tools, hold the model as a plain stored property on the `App` struct.
- `AudioHardwareCreateProcessTap` blocks while the TCC prompt is on screen;
  gating on preflight first avoids freezing the UI.
- System Audio Recording changes made in System Settings never reach a running
  process: `TCCAccessPreflight` keeps returning the launch-time answer, and an
  existing grant keeps working. Only a relaunch picks up the new state.

## Verification

Verified by hand on macOS 27.0.1:

- Per-app attenuation and mute (Discord, Firefox, Music), live list updates,
  quit restores full volume.
- Pause all adjustments / Resume.
- Switching output (speakers ↔ wired headphones) with Music tapped keeps its
  gain, and a muted app stays silent across the switch.
- Relaunch with permission off: banner shown, rows greyed out, every app at
  full volume.
- Turning the permission on, then **Relaunch AudioControl**: one icon returns,
  the banner is gone and saved volumes apply.

Still owed:

1. Switch to AirPods (Bluetooth) with an app tapped: audio continues at the
   same gain; a muted app stays silent throughout.
