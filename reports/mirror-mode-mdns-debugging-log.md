# Mirror Screen mode debugging log

Chronological account of how we got from "port Blittie Projector to a web
app" to identifying the WebKit mDNS ICE-candidate root cause in
[`mirror-mode-mdns-findings.md`](./mirror-mode-mdns-findings.md). Written so
we don't retread the same dead ends if this comes up again.

## 1. Initial port

Read through the native macOS implementation (`../vga`): `AppModel`,
`ReceiverProtocol` (`WireProtocol.swift`, `ReceiverConnection.swift`,
`ReceiverEndpoint.swift`, `ReceiverBrowser.swift`), `SignalingCore`
(`mirror.html`, `receiver.html`, `common.js`, `BrowserPage.swift`), and
`BlittieScreen` (`ReceiverSocketServer.swift`, `SessionCoordinator.swift`).
Confirmed Bonjour/mDNS *discovery* isn't available to a browser (per the
user's own stated assumption going in) and scoped the port to manual address
entry only.

Built the web app (Vite + React + TypeScript): `wireProtocol.ts` (mirrors the
Swift JSON envelope), `receiverEndpoint.ts`, `receiverConnection.ts` (a
WebSocket client mirroring `ReceiverConnection.swift`'s reconnect/backoff),
`mirrorSession.ts` (ported directly from `mirror.html`/`common.js`, talking
to the connection directly instead of through the native `callJavaScript`
bridge), and the React components. Verified the build, unit-checked address
parsing, and did a best-effort visual check in Safari (only Chrome-based
`chrome-devtools` tooling was unavailable in this environment).

## 2. The TLS/mixed-content question

Identified up front that Screen's `ws://` listener has no TLS, and a browser
enforces mixed content (no `ws://` from an `https://` page) plus a secure
context requirement for `getDisplayMedia` (Mirror mode). Discussed options:
Let's Encrypt via DNS-01, a private CA (`mkcert`-style), and — since the user
already runs Tailscale on both machines — `tailscale serve` / `tailscale
cert`.

**Decision: use `tailscale serve`.** It terminates TLS with a real
Let's-Encrypt-backed cert on the MagicDNS hostname and reverse-proxies to
Screen's existing plain `ws://127.0.0.1:8787` listener, requiring **zero**
Receiver-side code changes. `serve` (not `funnel`) keeps it tailnet-only.

## 3. First real test — signaling works, media doesn't

Over Tailscale (`autosvcacct.tail12901.ts.net`): the WebSocket connected,
offer/answer exchanged successfully, but the media never connected.
Screen showed `connection: connecting / ice: connected`; the web Projector
sat at "connecting to Screen...".

Walked through reading `chrome://webrtc-internals`: found one candidate
pair, `nominated: false`, `state: waiting`, local candidate type `host`,
remote candidate type `prflx`.

**Hypothesis #1 (later disproven as the primary cause):** Chrome's
mDNS-obfuscated host candidates can't resolve across the Tailscale tunnel
(mDNS is multicast-scoped; Tailscale is an L3 WireGuard overlay, not a
bridged LAN segment), combined with no STUN/TURN fallback (`iceServers: []`,
matching the original LAN-only trust model).

## 4. TURN detour (implemented, then reverted)

Started building a TURN-relay fix: added TURN server config to
`mirrorSession.ts`'s `iceServers`, and planned the matching native-side
change (both peers need to allocate a relay candidate from the *same* TURN
server for pairing to work — this would have meant editing
`common.js`/`receiver.html` in `../vga` too, not just the web app).

**User declined**: running relay infrastructure (`coturn` + credentials +
firewall considerations) was more complexity than warranted for something
that isn't the primary client surface. Reverted the `mirrorSession.ts`
changes back to `iceServers: []`.

## 5. Self-signed cert + dual listener, instead of Tailscale Serve

New direction: give Screen a second, TLS-wrapped `wss://` listener
(`ReceiverEndpoint.defaultWSSPort = 8788`) alongside the existing plain
`ws://:8787` one, using a self-signed certificate the operator generates
once and each browser/device trusts once via a direct `https://` visit.
Explicitly flagged at the time: this fixes TLS/mixed-content, but does
**not** address the mDNS/ICE issue unless Projector and Screen actually
share a LAN (removing Tailscale-the-tunnel from the equation, not just
Tailscale-the-TLS-terminator).

Implemented in `ReceiverSocketServer.swift`: `startPlainListener()` /
`startTLSListener()` split, loading a `sec_identity_t` from a PKCS#12 file
via `SecPKCS12Import`. Verified with `swift build`.

**Sandboxing gotcha:** first attempt built the identity path off
`FileManager.default.homeDirectoryForCurrentUser`. BlittieScreen has
`ENABLE_APP_SANDBOX = YES` (confirmed via `project.pbxproj`), which
transparently redirects that to the app's own container
(`~/Library/Containers/com.wesleymoy.BlittieScreen/Data/...`), not the real
home directory — so the cert placed at the real
`~/Library/Application Support/...` path was invisible to the sandboxed
process, and `wss://:8788` never started (silently — it only logs to
stderr, no in-app indication). **Fixed** by switching to
`FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`,
which resolves correctly regardless of sandbox status.

## 6. Retest on a plain LAN — same failure

Switched off Tailscale entirely for this: Screen reachable only via
`autosvcacct.local` / `192.168.1.110`, cert regenerated with both as SANs.
`wss://` connected fine (green "Connected" status, offer/answer exchanged).
**Identical WebRTC symptom**: single `prflx` pair, `waiting`, never
nominated.

This directly disproved Hypothesis #1 — a real shared LAN should have let
mDNS resolve fine if the tunnel were the actual problem. It didn't, so the
tunnel was never the real variable.

## 7. Ruling out the self-signed cert itself

User asked directly whether the self-signed `wss://` cert could be
interfering with the WebRTC connection, and whether a CA-trusted cert would
help. Explained the two are architecturally independent: `wss://` signaling
trust is browser-cert-store-based; WebRTC's DTLS media encryption uses
ephemeral, self-generated per-connection certs authenticated via SDP
fingerprint pinning, not a CA at all. Confirmed not relevant — the
offer/answer round trip was already completing successfully before ICE (a
strictly earlier stage than DTLS) ever stalled.

## 8. mDNS/ICE mechanics explainer

Explained, on request: non-trickle ICE means the full offer/answer,
including every embedded `a=candidate:` line, travels over the WebSocket as
inert text — signaling doesn't know or care what's inside. mDNS obfuscation
happens client-side at candidate-*gathering* time, before the SDP text even
exists, substituting a `<uuid>.local` FQDN for the real IP in the
candidate's connection-address field. The specific ICE operation blocked is
the *receiving* agent's need to perform a live mDNS query to resolve that
FQDN before it can even attempt a STUN connectivity check — an operation
that happens out-of-band, after signaling, and has nothing to do with the
WebSocket transport.

Also explained Chrome's rationale for mDNS obfuscation on request: closes a
long-standing privacy leak where any page could read a user's real local IP
via WebRTC with zero permission prompt (fingerprinting + local-network
reconnaissance, related to historical "WebRTC leak" complaints from VPN
users). Designed to be invisible to genuine same-LAN peers (multicast
resolves fine locally) while blocking remote/third-party observers. No
page-level opt-out exists by design — only a browser-level flag.

## 9. Directly testing whether the mDNS name resolves at all

Added a temporary `console.log(pc.localDescription.sdp)` in
`mirrorSession.ts` to extract the literal `<uuid>.local` candidate name —
Chrome hides it even from its own `webrtc-internals` stats tables (shows as
`(not set)`), so the raw SDP text (which the page has legitimate access to,
since it has to send it to the peer) was the only way to get it out.

- `ping <name>.local` → succeeded.
- First attempt at `dns-sd -q`, `ping6`, `nc -vz` (run later, after some
  time had passed, and from a different terminal prompt than the original
  successful `ping`) → **all failed** uniformly with "nodename nor servname
  provided." Root-caused to two compounding issues: (a) the mDNS
  registration is tied to the live `RTCPeerConnection`'s lifetime, and
  enough time had elapsed that Chrome had likely stopped answering for that
  specific name; (b) a possible cross-machine mismatch (new prompt showed a
  different machine name). Recommendation going forward: always retest
  immediately after a fresh "Start Mirroring" click, tight timing, same
  machine throughout.

## 10. Clean retest, isolated to one machine

User ran Chrome (Projector) and Screen on the same machine ("Goldenrod") to
remove network-path variables and iterate faster — confirmed as a
completely valid simplification for this diagnosis (doesn't compromise
anything we're testing), with a note to retest on `autosvcacct` once
something actually works.

Fresh results, tight timing:
- `dns-sd -q <name>.local` → resolved a clean A record (`192.168.1.121`) in
  ~2 seconds.
- `ping6 <name>.local` → failed — **no AAAA record exists at all**,
  disproving the IPv6/Happy-Eyeballs-stall theory that had been the leading
  explanation for a separate, very long Safari address-bar hang observed
  around this time.
- `nc -vz <name>.local 80` → immediate, clean "Connection refused" — full
  network/TCP path confirmed healthy end to end.
- `ping <name>.local` → still succeeded, consistent.

Conclusion at this point: the OS-level `mDNSResponder` resolution and TCP
connectivity are completely healthy for the exact address in question. The
earlier Safari-navigation hang was most likely an artifact of Safari's own
URL-loading heuristics (e.g. an automatic HTTPS-upgrade attempt to a
different port than we'd tested), not evidence about the real problem — a
proxy test whose fidelity to the actual failing code path (WebKit's
libwebrtc ICE resolver) turned out to be lower than hoped.

## 11. Inspecting the real thing directly

Pivoted from proxy tests to inspecting the actual failing code path. Added
`webView.isInspectable = true` to `BrowserPage.swift` (macOS 13.3+) so
Safari's Develop menu can attach directly to a live `receiver.html`
instance.

With Web Inspector attached during a stalled mirror attempt:
- `[pc.connectionState, pc.iceConnectionState, pc.iceGatheringState]` →
  `["new", "new", "complete"]`. Gathering had already finished — meaning
  `receiver.html`'s "gathering ICE candidates..." status text was stale
  (separate, minor bug: `wireConnectionStatus`'s label only updates on
  `connectionstatechange`/`iceconnectionstatechange`, never on
  `icegatheringstatechange`, and gets overwritten by a one-time manual
  status update right before the gathering wait begins).
- `pc.getStats()` → Screen's own 4 local candidates present, but **zero**
  `remote-candidate` entries and **zero** `candidate-pair` entries. WebKit's
  ICE agent had not incorporated any of Chrome's candidates at all — not
  "still resolving," genuinely absent from its candidate list.

## 12. Root cause confirmed

A web search turned up documentation (see Sources in the findings doc)
confirming WebKit's mDNS ICE-candidate *resolution* support ships as an
experimental feature, off by default, and that ICE stacks broadly fail to
parse/use FQDN-form candidate addresses unless they specifically implement
this extension. This is consistent with every piece of evidence gathered:
native WebKit-to-WebKit mirroring always worked (mDNS never actually
involved on either side), Chrome→WebKit failed identically regardless of
network topology (never actually a routing problem), and WebKit's own stats
showed zero remote candidates (dropped, not failed-to-resolve).

See [`mirror-mode-mdns-findings.md`](./mirror-mode-mdns-findings.md) for the
consolidated conclusion and options going forward — none of which have been
applied yet as of this writing.
