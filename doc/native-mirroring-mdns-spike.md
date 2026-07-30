# Native WebRTC mirroring for Blittie Screen: mDNS interop spike

Status: **validated, ready to move to implementation**
Date: 2026-07-30
Scope: `~/src/vga` (the Blittie monorepo — `BlittieScreen`, `BlittieProjector`, `SignalingCore`, `ReceiverProtocol`)

## The goal

Rebuild `BlittieScreen`'s screen-mirroring receive path (currently WKWebView
+ `receiver.html`, see `vga/Sources/BlittieScreen/SessionCoordinator.swift`
and `vga/Sources/SignalingCore/Resources/receiver.html`) in native code: a
real `RTCPeerConnection` plus native video rendering, instead of a WebView
running JS WebRTC. The video-by-URL path (YouTube/Dropout playback via
`VideoParser`) stays on WebView — only screen mirroring moves.

This doc is *not* the implementation plan (that lives in conversation
history / will be re-derived as a plan when implementation starts). It
records **why this is worth doing** and **what we already proved**, so that
work doesn't need to be re-derived from scratch.

## The problem this solves

`BlittieScreen`'s receiver, and `BlittieProjector`'s sender, both currently
run their WebRTC/SDP logic inside `WKWebView` (`receiver.html` /
`mirror.html`, `common.js`). That means the receiver's ICE/WebRTC stack is
whatever WebKit ships, not a browser-agnostic implementation.

If a *third-party* browser (e.g. plain Chrome, not `BlittieProjector`) tries
to act as a Sender against this receiver, the connection fails. Root cause:

- Chrome (and Chromium-based browsers generally) obfuscate host ICE
  candidates behind a random-UUID `<uuid>.local` mDNS name, unconditionally,
  as a privacy feature. A website has no way to opt out of this.
- Safari/WebKit's WebRTC stack is an independent implementation from
  Chromium's, and has real, documented gaps in mDNS-candidate interop with
  Chrome:
  - [WebKit bug 209050 — "Safari doesn't insert mDNS candidates to SDP"](https://bugs.webkit.org/show_bug.cgi?id=209050)
  - Mozilla bugs describing the same category of cross-engine mDNS breakage:
    [1507700](https://bugzilla.mozilla.org/show_bug.cgi?id=1507700),
    [1548841](https://bugzilla.mozilla.org/show_bug.cgi?id=1548841),
    [1698141](https://bugzilla.mozilla.org/show_bug.cgi?id=1698141)
- So a Chrome Sender's offer arrives with only `.local` host candidates, and
  the WebKit-based receiver can't resolve them → no connectivity, no TURN/STUN
  to fall back on (this project is intentionally LAN-only, no relay).

**Hypothesis going in:** if the receiver's ICE stack is *literally the same
codebase Chrome uses* (Google's libwebrtc, native, not WebKit's fork),
Chrome-to-native interop should work, because it removes the cross-vendor
implementation divergence that's the actual root cause.

This was a real hypothesis, not a certainty — see "what could still be
wrong" in the spike section below for what it didn't automatically prove.

## Prior related work already in the repo

`vga` has an earlier, different attempt at solving this **same underlying
problem**, on a divergent (unmerged) commit not on `main`:

```
qkumpvxr df735ca5 "Embed a TURN server in Screen so Chrome-based Senders can connect"
```

(`jj show qkumpvxr` in `vga` to view it in full; not reachable from `main`
or any bookmark except by change ID.)

That approach sidesteps the mDNS problem entirely rather than fixing it:
`TurnServer.swift` embeds a minimal, unauthenticated TURN relay (RFC 8656)
directly in `BlittieScreen`, so a Chrome Sender gets a real relayed/
server-reflexive candidate it can use regardless of whether the receiver can
resolve `.local` names. It's a substantial, working implementation (534
lines + wire-protocol changes + tests) but adds real complexity: a hand-rolled
TURN server, a raw BSD socket for the relay (Network.framework's per-flow
`NWConnection` model doesn't fit multi-peer relaying), and the security
surface of an unauthenticated relay (mitigated only by "LAN-only trust
model," same as the rest of this project).

**Open question for whoever picks this up:** once native mirroring (this
doc) lands, does the TURN-server branch become unnecessary, stay as a
fallback for networks that block multicast (where mDNS resolution can't work
*regardless* of which WebRTC stack is used — see "residual risks" below), or
get abandoned? Worth a deliberate decision rather than just letting it rot
unmerged. It predates this investigation and its commit message
independently arrives at the same root-cause diagnosis as above, which is
good corroborating evidence.

## The spike

Before committing to the native-mirroring rebuild (new `NativeMirror` SPM
target, `NativeMirrorSession`/`NativeMirrorView`, rewiring
`SessionCoordinator`, deleting `receiver.html` — the real implementation
plan), we isolated the one risky, unverified assumption and tested it
directly: **does a native macOS process using Google's libwebrtc actually
resolve a real Chrome-generated mDNS candidate and reach `connected`?**

### Setup

A throwaway, standalone Swift package (not part of `vga`, built and run
outside any repo, since it was disposable) with one dependency:

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MDNSSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "150.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MDNSSpike",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")]
        ),
    ]
)
```

`stasel/WebRTC` is a community-maintained distribution of Google's prebuilt
libwebrtc XCFramework binaries, confirmed to support macOS (`.macOS(.v10_11)`
in its own manifest), and confirmed to actually build/link/run on macOS 15 /
Swift 6.4 / Xcode 27 during this spike.

The harness (`Sources/MDNSSpike/MDNSSpike.swift`) is a bare
`RTCPeerConnection` — no `SessionCoordinator`, no window management, nothing
Blittie-specific beyond matching its LAN-only ICE config:

```swift
import Foundation
@preconcurrency import WebRTC

// stdout is fully block-buffered when redirected to a file/pipe (unlike a
// TTY), and this process deliberately never exits (RunLoop.main.run() at the
// bottom) — without this, output past the last buffer flush is invisible to
// anything tailing the redirected log.
setvbuf(stdout, nil, _IONBF, 0)

func stringForIceConnectionState(_ state: RTCIceConnectionState) -> String {
    switch state {
    case .new: return "new"
    case .checking: return "checking"
    case .connected: return "connected"
    case .completed: return "completed"
    case .failed: return "failed"
    case .disconnected: return "disconnected"
    case .closed: return "closed"
    default: return "unknown(\(state.rawValue))"
    }
}

func stringForIceGatheringState(_ state: RTCIceGatheringState) -> String {
    switch state {
    case .new: return "new"
    case .gathering: return "gathering"
    case .complete: return "complete"
    default: return "unknown(\(state.rawValue))"
    }
}

func stringForPeerConnectionState(_ state: RTCPeerConnectionState) -> String {
    switch state {
    case .new: return "new"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .disconnected: return "disconnected"
    case .failed: return "failed"
    case .closed: return "closed"
    default: return "unknown(\(state.rawValue))"
    }
}

func stringForSignalingState(_ state: RTCSignalingState) -> String {
    switch state {
    case .stable: return "stable"
    case .haveLocalOffer: return "haveLocalOffer"
    case .haveLocalPrAnswer: return "haveLocalPrAnswer"
    case .haveRemoteOffer: return "haveRemoteOffer"
    case .haveRemotePrAnswer: return "haveRemotePrAnswer"
    case .closed: return "closed"
    default: return "unknown(\(state.rawValue))"
    }
}

let startedAt = Date()
func log(_ message: String) {
    let elapsed = String(format: "%6.2f", Date().timeIntervalSince(startedAt))
    print("[+\(elapsed)s] \(message)")
}

final class SpikeDelegate: NSObject, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log("signaling state -> \(stringForSignalingState(stateChanged))")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        log("didAdd stream \(stream.streamId) — video tracks: \(stream.videoTracks.count), audio tracks: \(stream.audioTracks.count)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        log("didRemove stream \(stream.streamId)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        log("didAdd receiver, track kind: \(rtpReceiver.track?.kind ?? "nil")")
    }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        log("shouldNegotiate")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log("ICE connection state -> \(stringForIceConnectionState(newState))")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log("ICE gathering state -> \(stringForIceGatheringState(newState))")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log("peer connection state -> \(stringForPeerConnectionState(newState))  <-- the number we care about")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log("local candidate: \(candidate.sdp)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        log("removed \(candidates.count) local candidate(s)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("didOpen data channel")
    }
}

print("""
=== Blittie native-WebRTC mDNS spike ===

Paste the FULL offer SDP captured from Chrome below, then press Enter
followed by Ctrl-D to finish input.

""")

var inputLines: [String] = []
while let line = readLine(strippingNewline: true) {
    inputLines.append(line)
}
// Trailing CRLF terminator matters — see "gotchas" below.
let offerSDPText = inputLines.joined(separator: "\r\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\r\n"

guard !offerSDPText.isEmpty else {
    FileHandle.standardError.write(Data("No SDP provided — aborting.\n".utf8))
    exit(1)
}

RTCInitializeSSL()
let factory = RTCPeerConnectionFactory()

let config = RTCConfiguration()
// Matches Blittie's LAN-only trust model (common.js's createPeerConnection):
// no STUN/TURN.
config.iceServers = []
config.sdpSemantics = .unifiedPlan
// Non-trickle, matching common.js's waitForIceGatheringComplete pattern —
// gather everything up front rather than streaming candidates.
config.continualGatheringPolicy = .gatherOnce

let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
let delegate = SpikeDelegate()
guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
    FileHandle.standardError.write(Data("Failed to create RTCPeerConnection.\n".utf8))
    exit(1)
}

let offer = RTCSessionDescription(type: .offer, sdp: offerSDPText)

let remoteSet = DispatchSemaphore(value: 0)
pc.setRemoteDescription(offer) { error in
    if let error { log("setRemoteDescription FAILED: \(error)"); exit(1) }
    remoteSet.signal()
}
remoteSet.wait()

let answerReady = DispatchSemaphore(value: 0)
pc.answer(for: constraints) { sdp, error in
    guard let sdp else { log("createAnswer FAILED: \(error?.localizedDescription ?? "?")"); exit(1) }
    pc.setLocalDescription(sdp) { error in
        if let error { log("setLocalDescription FAILED: \(error)"); exit(1) }
        answerReady.signal()
    }
}
answerReady.wait()

while pc.iceGatheringState != .complete {
    Thread.sleep(forTimeInterval: 0.2)
}

print("=== ANSWER SDP — paste into Chrome's console ===\n\(pc.localDescription?.sdp ?? "")")

// Stays alive so delegate callbacks (ICE/connection state) keep printing.
RunLoop.main.run()
```

Run via a small wrapper, since a bare (non-app-bundle) SPM executable
doesn't inherit the XCFramework's rpath the way a real `.app` does — see
gotchas:

```sh
#!/bin/sh
cd "$(dirname "$0")"
swift build || exit 1
DYLD_FRAMEWORK_PATH="$(pwd)/.build/out/Products/Debug" exec .build/out/Products/Debug/MDNSSpike
```

### Getting a real Chrome offer

Signaling was done **by hand** (this was a one-off spike, not worth building
real signaling for): paste into Chrome DevTools console on any `https://`
tab. Wrapped in a button click specifically because `getDisplayMedia()`
requires a real user gesture — calling it directly from the console doesn't
reliably count as one:

```js
(() => {
  const btn = document.createElement('button');
  btn.textContent = 'Blittie spike: capture screen + create offer';
  btn.style.cssText = 'position:fixed;top:10px;left:10px;z-index:999999;padding:12px 16px;font-size:14px;';
  document.body.appendChild(btn);

  btn.onclick = async () => {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
    window.pc = new RTCPeerConnection({ iceServers: [] });
    stream.getTracks().forEach(t => window.pc.addTrack(t, stream));

    const offer = await window.pc.createOffer();
    await window.pc.setLocalDescription(offer);

    if (window.pc.iceGatheringState !== 'complete') {
      await new Promise((resolve) => {
        window.pc.addEventListener('icegatheringstatechange', function check() {
          if (window.pc.iceGatheringState === 'complete') {
            window.pc.removeEventListener('icegatheringstatechange', check);
            resolve();
          }
        });
      });
    }

    const sdp = window.pc.localDescription.sdp;
    console.log('=== OFFER SDP ===\n' + sdp);
    await navigator.clipboard.writeText(sdp).catch(() => {});

    window.pc.addEventListener('iceconnectionstatechange', () => {
      console.log('[chrome] ICE connection state ->', window.pc.iceConnectionState);
    });
    window.pc.addEventListener('connectionstatechange', () => {
      console.log('[chrome] connection state ->', window.pc.connectionState);
    });
  };
})();
```

This mirrors `mirror.html`'s actual behavior: no STUN/TURN (`iceServers: []`),
non-trickle (wait for `iceGatheringState === 'complete'` before treating the
offer as ready) — same LAN-only, self-contained-SDP-blob model as the real
app.

The offer/answer exchange itself was manual copy-paste between the Chrome
console and the native tool's stdin/stdout (again: fine for a one-off spike,
would obviously be automated/direct in the real implementation, where Swift
and JS — or Swift and Swift — talk to each other in-process rather than
through a human).

### Result: confirmed

```
[+ 24.79s] peer connection state -> connected  <-- the number we care about
[+ 24.79s] ICE connection state -> connected
```

...logged by the **native** process, matched by Chrome's own console logging
`[chrome] ICE connection state -> connected` / `[chrome] connection state ->
connected`.

This is strong evidence, not just a plausible-looking log line: the tested
offer had **exactly one** ICE candidate — the `.local` mDNS one
(`a=candidate:... udp ... 0b066082-5463-43a0-9f67-9ed1e94db5f7.local ... typ host`).
There was no other candidate available for connectivity to succeed through,
so reaching `connected` means the native side actually resolved the mDNS
name and completed a real ICE connectivity check against Chrome.

**Conclusion:** a native macOS receiver using Google's libwebrtc (via
`stasel/WebRTC` 150.0.0) resolves Chrome's mDNS ICE candidates out of the
box. No custom `.local`-resolution shim, no `AsyncDnsResolverFactory`
plumbing, nothing beyond a stock `RTCPeerConnection` was needed. The
root-cause theory (WebKit's independent ICE/mDNS implementation diverging
from Chromium's) holds up, and using the same codebase Chrome uses removes
that divergence.

### Gotchas hit along the way (so they don't need re-discovering)

- **dyld/rpath**: a bare SPM executable (not an app bundle) linking an
  XCFramework binary target fails at launch with `Library not loaded:
  @rpath/WebRTC.framework/WebRTC` unless `DYLD_FRAMEWORK_PATH` is pointed at
  the built `WebRTC.framework` manually (see the `run.sh` wrapper above).
  **This is specific to bare command-line executables** — a real `.app`
  bundle (which `BlittieScreen` already is, via `Blittie.xcodeproj`) embeds
  and code-signs frameworks properly at build time, so this workaround
  shouldn't be needed in the real integration. Worth a quick sanity check
  early regardless.
- **SDP needs a trailing CRLF terminator.** Omitting it made
  `RTCSessionDescription`'s lazy native parse fail silently, surfaced only as
  an unhelpful generic `Error Domain=org.webrtc.RTC_OBJC_TYPE(RTCPeerConnection)
  Code=-1 "SessionDescription is NULL."` — `stasel/WebRTC`'s wrapper doesn't
  propagate the real libwebrtc parse-error detail (line number, reason).
- **A stray blank line inside an SDP body is also a hard parse failure**
  (`Invalid SDP line`), and one was trivial to accidentally introduce by
  extracting the SDP from between `BEGIN`/`END` markers in printed log
  output (there was a blank line in the print template right before the
  `END` marker) — worth being careful about when the SDP round-trips through
  any text-processing step.
- **Manual copy-paste of a ~5KB SDP blob through a chat/terminal UI is
  genuinely lossy** — hit both silent truncation (partial copy, produced a
  confusing `RTP extension ID reassignment` error with a visibly truncated
  URI in the message) and the blank-line issue above. This was purely an
  artifact of doing a *manual* two-party test for the spike; the real
  integration has no manual step (Swift and JS, or Swift and Swift, hand the
  SDP directly to each other in-process), so this class of bug doesn't carry
  forward — but if anyone else needs to manually drive an SDP exchange for
  debugging later, don't hand-copy through a chat window; write it to a file
  and copy from an editor instead.
- **`stdout` is fully block-buffered** when redirected to a file/pipe
  (unlike a TTY) — and this tool deliberately never exits
  (`RunLoop.main.run()`), so without `setvbuf(stdout, nil, _IONBF, 0)`,
  anything tailing the redirected log sees stale/truncated output.
- Top-level Swift script code can't use a bare `guard ... else { <no exit> }`
  — the `else` body must exit scope (`return`/`throw`/`exit(...)`), even at
  top level, unlike inside a function where the enclosing control flow makes
  this more forgiving in some other languages' scripting modes.
- Chrome's `RTCPeerConnection` will go to `signalingState: 'closed'` if left
  sitting idle mid-handshake for too long (hit this restarting the spike
  after a pause) — if that happens, there's no salvaging the old `pc`; the
  Chrome-side button needs a fresh click (or the console snippet needs
  re-pasting if the tab reloaded) to get a new offer, and the native side
  needs restarting to accept it.

## What this doesn't prove / residual risks for the real feature

None of these are blockers, and none are specific to the native-vs-WebView
choice — they're inherent to the mDNS/LAN-only approach in general and would
affect the existing WebView-based receiver just the same:

- **Firefox has its own independent mDNS-candidate implementation**, separate
  from Chromium's/libwebrtc's. This spike only validated Chrome interop;
  Firefox (or other engines) would need their own check if "arbitrary
  browser Sender" needs to cover them.
- **Multicast gets filtered on plenty of networks** (guest Wi-Fi, VPNs, some
  corporate LANs — see the Mozilla bug about the 1-hop TTL limit above). No
  WebRTC stack choice fixes this; it's inherent to relying on
  mDNS-obfuscated candidates without a TURN server. This is exactly the
  scenario the existing (unmerged) TURN-server branch would still cover —
  see "prior related work" above.
- **Secure-context requirement**: `getDisplayMedia` needs `https://` (or
  `localhost`) on the sending page. `ReceiverSocketServer` already runs a
  `wss://` listener alongside `ws://` for exactly this reason, so this was
  already anticipated by the existing code.
- **Signaling**: `WireProtocol`'s bespoke JSON/WebSocket envelope is
  Blittie-specific. A truly arbitrary third-party browser Sender would need
  its own client speaking that protocol — separate front-end work, unrelated
  to this spike.

## Where to resume

The implementation plan discussed alongside this spike (not repeated here in
full, but summarized for orientation):

1. New `NativeMirror` SPM library target in `vga/Package.swift`, depending on
   `stasel/WebRTC` 150.0.0 (now a known-working version/config, confirmed
   above — no need to re-evaluate other candidates like
   `livekit/webrtc-xcframework` or `Bandwidth/webrtc-swift`).
2. `NativeMirrorSession` (`@MainActor`): native analog of `receiver.html` —
   `acceptOffer(_:) -> (session, answerSDP)`, `readyEvents`/
   `disconnectedEvents: AsyncStream<Void>` replacing the
   `blittieMirrorReady`/`blittieMirrorDisconnected` postMessages,
   `teardown()` replacing `window.__blittieTeardown`. `@preconcurrency import
   WebRTC` to deal with the ObjC bridge not being `Sendable`-audited.
3. `NativeMirrorView`: `NSViewRepresentable` around the Metal-backed remote
   video view.
4. Rewire `vga/Sources/BlittieScreen/SessionCoordinator.swift`: `startOffer`
   builds a `NativeMirrorSession` instead of loading `receiver.html` into a
   `BrowserPage`. Also fixes a pre-existing inconsistency noticed along the
   way — `startOffer` currently sets `fullscreenStrategy = .element` (line
   ~97), which contradicts the large comment on `FullscreenStrategy`
   explaining why mirror needs `.window`-level fullscreen; a native `NSView`
   has no HTML Fullscreen API at all, so this refactor forces the mirror path
   onto `.window`, resolving that inconsistency as a side effect.
5. Delete `receiver.html`, the `SignalingRole.receiver` case, and the
   `blittieMirror*` message-name plumbing once the native path is verified.
   `mirror.html`/`common.js`/`BlittieProjector` are untouched — out of scope.
6. Decide the fate of the `qkumpvxr` TURN-server branch (see "prior related
   work" above).
