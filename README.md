# VGA Sender (iOS)

A native iOS counterpart to `vga`'s macOS Sender: sends a YouTube URL or a
live screencast of the phone to a Receiver on the same LAN, using the same
unauthenticated HTTP + WebRTC protocol as `vga/Sources/Receiver/ControlServer.swift`.

## Architecture

- `Sender/` — the main app. SwiftUI UI (`ContentView.swift`) plus
  `BroadcastPickerView.swift`, a thin wrapper around `RPSystemBroadcastPickerView`
  (the system control that starts a broadcast — apps can't start one
  programmatically).
- `SenderBroadcastExtension/` — a Broadcast Upload Extension target.
  ReplayKit launches this as a *separate process* (under a ~50MB memory
  ceiling) when the user starts a broadcast. `SampleHandler.swift`
  (`RPBroadcastSampleHandler`) receives video frames from the whole device
  screen and hands them to `WebRTCSender.swift`, a video-only
  `RTCPeerConnection` that does the same offer/wait-for-ICE-gathering/POST
  `/offer`/answer handshake as the Mac Sender's JS.
- `Shared/SenderKit/` — a local Swift package (mirrors `vga`'s `SignalingCore`
  pattern) with the pieces shared between the app and the extension: the SDP
  JSON model, the Receiver HTTP client, and the receiver-address setting
  (persisted via an **App Group**, since the app and the extension are
  separate processes and need to see the same value).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.
  `VGASender.xcodeproj` is generated from it — regenerate with `xcodegen
  generate` after editing `project.yml`.

### Why an extension, not ScreenCaptureKit

I first built this on `SCContentSharingPicker`/`SCStream` (ScreenCaptureKit,
newly brought to iOS in the 27 SDK on this Mac), which runs in the main app
process with no extension/App Group/memory ceiling at all — genuinely
simpler. But that's iOS 27+ only, and your phone is on iOS 26, so those APIs
don't exist on your hardware. Screen capture on iOS 26 has to go through a
Broadcast Upload Extension (`RPBroadcastSampleHandler`) instead, which is
what's implemented now. `RPBroadcastSampleHandler` shows as deprecated in
the iOS 27 SDK, but only as of iOS 27 — targeting iOS 26 it's fully current,
still the only whole-device capture path available.

Deployment target is set to iOS 26.0 to match your device. If you ever want
an iOS 27+ ScreenCaptureKit path added as a second, better-performing branch
for newer devices, that's a distinct code path (not a drop-in) — ask and
I'll add it behind an `#available` check rather than replacing this.

## What you need to do

1. **Open the project.** `open VGASender.xcodeproj` (or `xcodegen generate`
   first if you've changed `project.yml`).
2. **Pick your iPhone as the run destination.** The Simulator can build this
   (unlike the ScreenCaptureKit version), but a Broadcast Extension can't
   actually capture anything there — use a real device to test screencasting.
3. **Signing**: `project.yml` sets `DEVELOPMENT_TEAM: 5D7367Q3PH` (copied
   from the existing `vga/VGA.xcodeproj`, assuming that's your team) with
   automatic signing for both targets. If Xcode complains, check each
   target's Signing & Capabilities tab — you may need to pick your team from
   the dropdown once per target. Both targets also need the App Group
   capability (`group.com.wesleymoy.vgasender`) — XcodeGen writes this into
   each target's entitlements file, but if Xcode's automatic signing balks
   at registering the group, add it manually via Signing & Capabilities →
   "+ Capability" → App Groups on each target.
4. **Trust the developer / enable Developer Mode** on the iPhone the first
   time you run a debug build from Xcode, if prompted (Settings → Privacy &
   Security → Developer Mode).
5. **Run Receiver on your Mac** (`swift run Receiver` from `vga/`, or the
   built Receiver.app) so it's listening on port 8787.
6. **In VGA Sender**, enter the Mac's LAN address, e.g. `192.168.1.42:8787`,
   in the "Receiver address" field.

## Testing

- **YouTube**: paste a video URL, tap "Send to Receiver" — Receiver should
  play it fullscreen, same as from the Mac Sender.
- **Screencast**: tap the broadcast-picker button next to "Live screencast".
  iOS presents its standard broadcast picker sheet — pick "VGA Screencast"
  (the extension) and tap Start Broadcast. You may get a "local network"
  permission prompt (needed for the extension's POST to Receiver's `/offer`)
  — allow it. Watch Receiver: it should go fullscreen with your phone's
  mirrored screen within a couple of seconds. A red status-bar indicator
  means the broadcast is active; tap it (or the picker button again) to stop.

## Known limitations / things to flag back to me

- **Video only, no audio** in this first version — screen mirroring has no
  sound. YouTube playback is unaffected (Receiver plays that itself, audio
  and all). Audio would mean also handling `RPSampleBufferType.audioApp`/
  `.audioMic` in `SampleHandler.processSampleBuffer` and bridging that into a
  custom `RTCAudioSource`, which is more work than video — say the word if
  you want it added.
- **Same LAN only, no STUN/TURN** — identical trust model to the existing
  Mac Sender/Receiver pair (see `ControlServer.swift`'s own comment on this).
  Doesn't work over cellular or across networks.
- **Extension memory ceiling (~50MB)**: if the broadcast crashes or never
  goes live, this is the most likely cause. `WebRTCSender.swift` caps
  resolution at 1170×2532@20fps via `adaptOutputFormat(toWidth:height:fps:)`
  — lower these first if you hit memory pressure; also worth checking the
  device console (Xcode → Window → Devices and Simulators → View Device
  Logs) for a jetsam/memory-limit crash from the `SenderBroadcastExtension`
  process specifically.
- If the picker doesn't list "VGA Screencast" as an option at all, that
  usually means the extension didn't embed/register correctly — rebuild
  clean (`Product → Clean Build Folder`) and reinstall.
