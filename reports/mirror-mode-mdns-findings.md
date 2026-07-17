# Mirror Screen mode: Chrome ↔ WebKit WebRTC findings

**Status as of writing:** root cause identified; fix not yet applied.
**Scope:** affects Mirror Screen mode (WebRTC screen mirroring) only. Send
Video mode (YouTube URL + playback controls) is unaffected — it's plain JSON
over the WebSocket control channel and never touches ICE/WebRTC.

## Root cause

The web Projector (running in Chrome) cannot establish a WebRTC media
connection to Screen (a native macOS app whose mirroring page,
`receiver.html`, runs in a WKWebView / WebKit) because:

1. Chrome unconditionally obfuscates its own local ("host") ICE candidates
   behind a randomly-generated `<uuid>.local` mDNS name, as a standing
   privacy default. This cannot be disabled from page JavaScript — only via
   a browser-level flag (`chrome://flags/#enable-webrtc-hide-local-ips-with-mdns`)
   or enterprise policy.
2. WebKit's support for *resolving* mDNS-form ICE candidates ships as an
   **experimental feature that is off by default**. In its default
   configuration, WebKit does not add Chrome's `.local`-addressed candidate
   to its ICE agent's candidate list at all — not "tries and fails to
   resolve," but never incorporates it in the first place.
3. Because Screen's WebKit-based receiver never has a real, usable candidate
   for Chrome on file, ICE never forms a genuine negotiated candidate pair.
   The one candidate pair that *does* sometimes appear (see below) is a
   `prflx` (peer-reflexive) artifact, not a real negotiated path, and never
   completes.

This is a WebKit platform behavior, not a bug in this project's Swift or
TypeScript code. No amount of `receiver.html`/`ReceiverSocketServer.swift`
changes can fix it.

## What isn't the cause (ruled out — don't re-investigate these)

- **Not Tailscale/VPN routing.** The identical failure signature reproduced
  on a plain shared LAN (`autosvcacct.local` / `192.168.1.110`, no Tailscale
  involved) and even with both Chrome and Screen on the same machine. If it
  were about multicast not traversing a VPN tunnel, a real shared LAN or
  same-machine setup would have fixed it. It didn't.
- **Not the self-signed `wss://` certificate.** The signaling channel's TLS
  trust (browser-cert-store-based) and WebRTC's DTLS media encryption
  (ephemeral, self-generated per-connection certs, authenticated via SDP
  fingerprint pinning) are architecturally independent. The offer/answer
  round trip over `wss://` consistently completed successfully — the stall
  is one layer later, in ICE, which runs before DTLS ever gets a chance to
  start.
- **Not IPv6 / Happy Eyeballs.** `ping6 <name>.local` failed — there is no
  AAAA record for the generated mDNS name at all, so there's no IPv6 path
  for a dual-stack connection attempt to stall on.
- **Not macOS Local Network permission.** Already granted to BlittieScreen
  in System Settings, confirmed before this was ruled out as a variable.
- **Not App Sandbox networking entitlements.** Screen's `ws://` and `wss://`
  listeners both bind and accept connections fine; sandboxing only affected
  an unrelated file-path issue (see the debugging log) that was already
  fixed.
- **Not general network/mDNS health.** `dns-sd -q <name>.local`, `ping
  <name>.local`, and `nc -vz <name>.local 80` all succeeded cleanly and
  quickly (`dns-sd` resolved a real A record in ~2s; `nc` got an immediate
  "Connection refused," proving full TCP-level reachability) when run
  directly against the literal mDNS name Chrome generated. The OS-level
  `mDNSResponder` resolution and network path are completely healthy — the
  problem is specifically that WebKit's WebRTC stack doesn't use that
  facility (or an equivalent) for ICE candidate resolution by default.

## Key evidence

- `chrome://webrtc-internals` showed exactly one candidate pair:
  `nominated: false`, `state: waiting`, local candidate type `host`, remote
  candidate type `prflx`. Chrome's own `local-candidate` address field
  showed as `(not set)` — Chrome hides the mDNS name even from its own
  internals page, confirming obfuscation was active.
- Live inspection of Screen's actual `receiver.html` `RTCPeerConnection` via
  Safari Web Inspector (attached directly, after enabling
  `webView.isInspectable`) during a stalled mirror attempt:
  `pc.iceGatheringState` was `"complete"`, but `pc.getStats()` showed **zero**
  `remote-candidate` entries and **zero** `candidate-pair` entries — proof
  that WebKit's ICE agent never incorporated any of Chrome's offered
  candidates, consistent with the candidate being dropped rather than
  queued for (failed) resolution.
- A minor, separate UI bug surfaced during this: `receiver.html`'s status
  line ("gathering ICE candidates...") is stale once gathering actually
  completes — `wireConnectionStatus`'s label only updates on
  `connectionstatechange`/`iceconnectionstatechange`, never on
  `icegatheringstatechange`, so it can look "stuck" even after the answer
  has already been sent. Worth fixing independently of the mDNS issue.
- Public documentation (see Sources) confirms WebKit's mDNS ICE-candidate
  resolution is experimental/off-by-default, and that ICE stacks in general
  frequently fail to parse or use FQDN-form candidate addresses unless they
  specifically implement this extension — matching the observed behavior
  exactly.

## Options going forward (none yet applied)

1. **Disable Chrome's mDNS obfuscation**, one time, on whichever
   browser/device is used as the web Projector:
   `chrome://flags/#enable-webrtc-hide-local-ips-with-mdns` → Disabled. With
   this off, Chrome advertises its real LAN IP directly, and WebKit needs no
   resolution step at all. Tradeoff: a manual, per-browser/device setting —
   fine for a personal tool, not viable for a general public web app.
2. **Check Safari's Develop → Feature Flags** for a corresponding WebKit-side
   toggle to enable mDNS candidate resolution instead. Not yet checked at
   time of writing. If present and it works, this would be the "purest" fix
   (both sides keep obfuscating, both can resolve each other), but
   experimental flags aren't always exposed in shipping Safari builds.
3. **A TURN relay** (e.g. `coturn`, bound to the tailnet or LAN interface)
   would sidestep host-candidate resolution entirely, since relay
   candidates are plain reachable addresses, not mDNS names. This was
   scoped out and explicitly declined earlier in the project as more
   infrastructure than warranted for a non-primary client surface — noted
   here as the fallback if options 1–2 don't pan out.

## Sources

- [mDNS ICE Candidates — IETF 103 slides](https://datatracker.ietf.org/meeting/103/materials/slides-103-rtcweb-mdns-ice-candidates-00)
- [mDNS service for IP handling in WebRTC — Chromium issue tracker](https://issues.chromium.org/issues/40591226)
- [Handle incoming mDNS ICE candidates in webrtc signaling — Mozilla Bugzilla #1548841](https://bugzilla.mozilla.org/show_bug.cgi?id=1548841)
- [mDNS ICE candidates breaks WebRTC-P2P connection between two computers on same private LAN — Mozilla Bugzilla #1698141](https://bugzilla.mozilla.org/show_bug.cgi?id=1698141)
- [mDNS candidates allows determination of computer hostname — rtcweb-wg/mdns-ice-candidates #121](https://github.com/rtcweb-wg/mdns-ice-candidates/issues/121)
- [PSA: mDNS and .local ICE candidates are coming — BlogGeek.me](https://bloggeek.me/psa-mdns-and-local-ice-candidates-are-coming/)
- [tailscale serve command — Tailscale Docs](https://tailscale.com/kb/1242/tailscale-serve) (relevant to the earlier, since-abandoned Tailscale Serve approach — see debugging log)
- [Enabling HTTPS — Tailscale Docs](https://tailscale.com/docs/how-to/set-up-https-certificates) (same)
