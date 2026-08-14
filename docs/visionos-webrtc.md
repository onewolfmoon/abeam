# Getting WebRTC (MirrorKit) building for visionOS

Status as of 2026-08-14: not started. This documents the investigation into
what's blocking a visionOS build and the plan to unblock it.

## Why it doesn't build today

Two separate issues, only one of which is a real blocker:

1. **The vendored WebRTC binary has no visionOS slice.** `MirrorKit/Package.swift`
   pulls `WebRTC` from `onewolfmoon/WebRTC` (a fork of `stasel/WebRTC`, pinned
   at `150.0.0`). The resolved `WebRTC.xcframework` ships exactly four slices:
   `ios-arm64`, `ios-x86_64_arm64-simulator`, `ios-x86_64_arm64-maccatalyst`,
   `macos-x86_64_arm64`. No `xros`/`xrsimulator`. Upstream `stasel/WebRTC`
   doesn't publish one either (checked releases through M151) — Chromium's own
   GN build has no native `target_os="visionos"`, so nobody gets this for free.
   **This is the actual blocker.**

2. **`MirrorKit/Package.swift` doesn't declare `.visionOS` in `platforms:`.**
   Initially assumed this would also block a visionOS build outright. That's
   wrong: SwiftPM doesn't hard-fail on an undeclared platform, it just falls
   back to the oldest deployment target the installed SDK supports for that
   platform. Declaring `.visionOS(...)` explicitly is still worth doing for
   clarity and to set a floor matching the `@available(iOS 27, *)` gating
   already in `WebRTCMirrorSession.swift`/`ScreenPicker.swift`/
   `ScreenCaptureSession.swift`, but it was never the thing standing in the way.

`Abeam.xcodeproj` already lists `xros xrsimulator` in `SUPPORTED_PLATFORMS`
for the main app target, which depends on `MirrorKit` — so the app target is
already primed to attempt a visionOS build and would currently fail resolving/
linking the WebRTC dependency specifically.

## Disk space (from-source build)

Checked against the current machine (15GB free): **not enough**, if the plan
were to build WebRTC from source. `fetch --nohooks webrtc_ios` + `gclient
sync` alone runs ~5.6GB post-2020 (Chromium split the full history out of
standalone WebRTC checkouts). Ninja build output on top of that — for at
least a device + simulator slice, potentially ×2 OSes if targeting iOS and
visionOS separately — commonly pushes practical totals into the 20-40GB
range in community reports. If the from-source fallback (Track B below) ever
becomes necessary, target **40GB+ free**.

This turned out to likely be moot — see below.

## Better option found: `livekit/webrtc-xcframework`

`livekit/webrtc-xcframework` (built from `webrtc-sdk/webrtc-build`) is an
actively maintained fork that already ships `xros-arm64` and
`xros-arm64-simulator` slices. Verified directly (downloaded the release zip,
~67MB, inspected without extracting the whole thing):

- Both visionOS device and simulator slices are present in the xcframework,
  each with a full header set — including `RTCAudioDevice.h`, which stasel's
  **macOS** slice is missing (the reason `MirrorKitAudioBridge/RTCAudioDeviceShim.h`
  exists today, redeclaring the protocol by shape instead of importing the
  real header).
- Every ObjC selector `WebRTCMirrorSession.swift` / `HighLevelH264EncoderFactory.swift`
  call — `peerConnectionWithConfiguration:constraints:delegate:`,
  `videoSourceForScreenCast:`, `addTransceiverWithTrack:init:`,
  `RTCRtpTransceiverInit`, `sdpSemantics`, `networkPriority`,
  `kRTCMediaConstraintsVoiceActivityDetection` — is present in the xros
  headers. (Spot check, not exhaustive — see open questions.)
- MIT licensed. No redistribution concerns.
- Currently tracking Chromium/WebRTC **M144** (branch 7559), vs. stasel's
  **M150** currently pinned. `webrtc-sdk/webrtc-build` treats M144 as a
  maintained stable branch, not an abandoned one — patch releases have shipped
  roughly weekly from March 2026 through today (`m144.7559.13`, published
  2026-08-14).

### `onewolfmoon/WebRTC`'s role

`onewolfmoon/WebRTC` exists because Xcode Cloud requires every SPM dependency
to have the Xcode Cloud GitHub App installed on its repo, and installing that
app on `stasel/WebRTC` directly isn't an option — hence the fork-as-pass-through.
If we move forward, the plan is to **replace `onewolfmoon/WebRTC`'s history
wholesale with `livekit/webrtc-xcframework`'s**, keeping the same dependency
URL (`https://github.com/onewolfmoon/WebRTC`) and Xcode Cloud App
installation, just pointing its content at LiveKit's build instead of
stasel's. `MirrorKit/Package.swift` doesn't need to reference LiveKit's repo
directly.

## M150 → M144: what moving back a version costs

Real, but calibrated:

- **~5 months / 6 Chromium milestones of upstream changes not included** —
  bug fixes, any newly landed APIs, whatever's changed in WebRTC's own
  internals since M144 branched (~March 2026). I don't have a reliable
  CVE/security-fix diff between the two branches; `webrtc-sdk/webrtc-build`'s
  own changelog doesn't itemize CVEs, and Chromium's per-branch security
  backport practices for M144 vs. mainline weren't independently verified.
  Treat "M144 might be missing a security fix already in M150" as a real,
  unquantified possibility rather than a confirmed one.
- **It's a third-party patched build, not stock Google WebRTC** — same as
  stasel today, so not a *new* category of risk, but LiveKit's build carries
  its own patch set (frame cryptor/E2EE, etc.) on top of upstream. Behavior
  isn't guaranteed identical to vanilla WebRTC at either version.
- **Vendor coupling**: upgrade cadence becomes LiveKit's roadmap, not ours.
  stasel/WebRTC's whole purpose is tracking latest milestones closely; pinning
  to LiveKit's build means our next version bump happens whenever LiveKit
  next rebases (they've stayed on M144 patch releases since March 2026 with
  no rebase yet).
- **Needs re-validation, not just a recompile**: `HighLevelH264EncoderFactory.swift`
  hand-constructs a Level 4.0 H264 profile-level-id specifically because
  `RTCDefaultVideoEncoderFactory`'s stock entries cap at Level 3.1 — that's
  the most custom, lowest-level piece of code touching WebRTC's encoder API,
  and header presence doesn't guarantee identical runtime negotiation
  behavior across a 6-milestone gap. Same caution applies to the
  `RTCAudioDeviceShim.h` protocol-redeclaration trick, though LiveKit's build
  shipping the real `RTCAudioDevice.h` on every slice we care about
  (including macOS, per the header listing) may make the shim unnecessary
  going forward.

Counterweight: LiveKit runs this exact WebRTC core in production at real
scale as their own SDKs' foundation — that's meaningful field-testing stasel's
community distribution doesn't carry to the same degree, even if it's fewer
milestones fresh.

## Plan

### Track A — adopt LiveKit's build (no extra disk needed; do first)

1. Diff the full LiveKit (M144) vs. stasel (M150) header sets for anything
   MirrorKit or `ReceiverProtocol` actually touches — only six files were
   spot-checked so far.
2. Specifically scrutinize `RTCH264ProfileLevelId.h` / `RTCVideoEncoderFactory.h`
   against `HighLevelH264EncoderFactory.swift` — the highest-risk surface, per above.
3. Replace `onewolfmoon/WebRTC`'s contents with `livekit/webrtc-xcframework`'s
   (same dependency URL, new content/tags).
4. Update `MirrorKit/Package.swift`: dependency stays pointed at
   `onewolfmoon/WebRTC`, but the product name changes to `LiveKitWebRTC`; add
   `.visionOS(.v2)` (confirm exact floor via the xros-arm64 binary's embedded
   min-OS version) to `platforms:`; regenerate `Package.resolved`.
5. Rename `import WebRTC` / `@preconcurrency import WebRTC` →
   `LiveKitWebRTC` across `WebRTCMirrorSession.swift`,
   `HighLevelH264EncoderFactory.swift`, and the ObjC bridge
   (`MirrorKitAudioBridge.m`, `RTCAudioDeviceShim.h`, `MirrorKitAudioBridge.h`).
   Re-check whether `RTCAudioDeviceShim.h`'s redeclaration is still needed now
   that the real header ships on every relevant slice.
6. Rebuild for iOS device/simulator, macOS, and Mac Catalyst first —
   regression-test the vendor swap in isolation before touching visionOS, so
   a break is attributable to "new WebRTC vendor" vs. "visionOS-specific."
7. Build for visionOS Simulator, then device.
8. Independently verify `ScreenCaptureKit`'s `SCContentSharingPicker`/
   `SCContentFilter` actually work on visionOS — gated separately from
   WebRTC entirely, and currently the biggest unverified unknown in the
   whole feature. `ScreenPicker.swift`'s existing comment about
   `SCContentSharingPickerConfiguration` differing on iOS/visionOS suggests
   the code was already written with this in mind, but it hasn't been
   confirmed to work.
9. Test on a real Vision Pro device if available — the simulator may not
   fully validate capture/AV paths.

### Track B — from-source build (fallback only)

Only pursue if Track A turns up a hard API gap, or LiveKit's fork drops
visionOS support later.

1. Free 40GB+ before starting.
2. Install depot_tools, `fetch --nohooks webrtc_ios`, `gclient sync`.
3. Use `because-why-not/webrtc_visionpro_workspace`'s `setup_xros.sh`/
   `build_xros.sh` as the starting point rather than re-deriving the GN
   patches from scratch — they've already solved "GN has no
   `target_os=visionos`" by overriding `target_os="ios"` and swapping the
   sdkroot to `xros`.
4. Build device (`xros-arm64`) + simulator (`xros-arm64-simulator`; no
   x86_64 slice needed, Vision Pro Simulator is Apple Silicon-only) and
   package into an xcframework alongside the existing slices.
5. Publish to `onewolfmoon/WebRTC`, then follow steps 4-9 from Track A.

## Open questions

- Exact minimum visionOS version LiveKit's `xros-arm64` slice was built
  against (needed for the `.visionOS(...)` platform declaration).
- Whether `RTCAudioDeviceShim.h`'s workaround is still needed once every
  slice we use ships the real `RTCAudioDevice.h`.
- Whether visionOS's `ScreenCaptureKit` actually supports what
  `ScreenCaptureSession`/`ScreenPicker` need — unverified, independent of WebRTC.
- No confirmed CVE/security diff between WebRTC M144 and M150 branches.
