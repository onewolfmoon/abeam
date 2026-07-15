# Blittie Projector (iOS)

A native iOS counterpart to `vga`'s macOS Sender: sends a YouTube URL to a
Blittie Screen on the same LAN, using the same unauthenticated WebSocket
protocol as `vga/Sources/Receiver/ReceiverSocketServer.swift`.

## Architecture

- `Projector/` — the main app. SwiftUI UI (`ContentView.swift`).
- `ShareExtension/` — a share extension (`ShareViewController.swift`) so you
  can share a link directly from the YouTube app (or Safari, etc.) instead of
  copy-pasting into the main app. Mirrors `vga`'s macOS Sender share
  extension, but keeps its own receiver-address setting rather than an App
  Group, since extension containers don't share `UserDefaults` with the host
  app by default.
- `Shared/ProjectorKit/` — a local Swift package (mirrors `vga`'s
  `SignalingCore` pattern) with the pieces shared by the app: the persistent
  WebSocket connection to a Blittie Screen (`ReceiverConnection.swift`) and
  the receiver-address setting (`ReceiverAddressStore.swift`, persisted via
  `UserDefaults`).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.
  `BlittieProjector.xcodeproj` is generated from it — regenerate with
  `xcodegen generate` after editing `project.yml`.

## What you need to do

1. **Open the project.** `open BlittieProjector.xcodeproj` (or `xcodegen
   generate` first if you've changed `project.yml`).
2. **Signing**: `project.yml` sets `DEVELOPMENT_TEAM: 5D7367Q3PH` (copied
   from the existing `vga/VGA.xcodeproj`, assuming that's your team) with
   automatic signing. If Xcode complains, check the Projector target's
   Signing & Capabilities tab and pick your team from the dropdown.
3. **Trust the developer / enable Developer Mode** on the iPhone the first
   time you run a debug build from Xcode, if prompted (Settings → Privacy &
   Security → Developer Mode).
4. **Run your Blittie Screen on your Mac** (`swift run Receiver` from `vga/`,
   or the built Receiver.app) so it's listening on port 8787.
5. **In Blittie Projector**, enter the Mac's LAN address, e.g.
   `192.168.1.42:8787`, in the "Blittie Screen address" field.

## Testing

- **YouTube**: paste a video URL, tap "Send to TV" — your Blittie Screen
  should play it fullscreen, same as from the Mac Sender.
- **Share extension**: in the YouTube app, open a video, tap Share, and pick
  "Send to Blittie Screen" from the share sheet. Enter its address the first
  time (it's remembered after that, separately from the main app's setting)
  and tap Send.

## Known limitations / things to flag back to me

- **Same LAN only** — identical trust model to the existing Mac
  Sender/Receiver pair (see `ControlServer.swift`'s own comment on this).
  Doesn't work over cellular or across networks.
- **Naming in flux** — the paired macOS project (`vga`) has since renamed
  itself to Blittie Screen, including its Bonjour service type
  (`_blittie-screen._tcp`); this repo's browsing side has been updated to
  match. Internal `Receiver*` Swift type names here are still the old
  naming and can be renamed at leisure.
