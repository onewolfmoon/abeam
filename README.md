# VGA Sender (iOS)

A native iOS counterpart to `vga`'s macOS Sender: sends a YouTube URL to a
Receiver on the same LAN, using the same unauthenticated HTTP protocol as
`vga/Sources/Receiver/ControlServer.swift`.

## Architecture

- `Sender/` — the main app. SwiftUI UI (`ContentView.swift`).
- `Shared/SenderKit/` — a local Swift package (mirrors `vga`'s `SignalingCore`
  pattern) with the pieces shared by the app: the Receiver HTTP client
  (`ControlClient.swift`) and the receiver-address setting
  (`ReceiverAddressStore.swift`, persisted via `UserDefaults`).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.
  `VGASender.xcodeproj` is generated from it — regenerate with `xcodegen
  generate` after editing `project.yml`.

## What you need to do

1. **Open the project.** `open VGASender.xcodeproj` (or `xcodegen generate`
   first if you've changed `project.yml`).
2. **Signing**: `project.yml` sets `DEVELOPMENT_TEAM: 5D7367Q3PH` (copied
   from the existing `vga/VGA.xcodeproj`, assuming that's your team) with
   automatic signing. If Xcode complains, check the Sender target's Signing
   & Capabilities tab and pick your team from the dropdown.
3. **Trust the developer / enable Developer Mode** on the iPhone the first
   time you run a debug build from Xcode, if prompted (Settings → Privacy &
   Security → Developer Mode).
4. **Run Receiver on your Mac** (`swift run Receiver` from `vga/`, or the
   built Receiver.app) so it's listening on port 8787.
5. **In VGA Sender**, enter the Mac's LAN address, e.g. `192.168.1.42:8787`,
   in the "Receiver address" field.

## Testing

- **YouTube**: paste a video URL, tap "Send to Receiver" — Receiver should
  play it fullscreen, same as from the Mac Sender.

## Known limitations / things to flag back to me

- **Same LAN only** — identical trust model to the existing Mac
  Sender/Receiver pair (see `ControlServer.swift`'s own comment on this).
  Doesn't work over cellular or across networks.
