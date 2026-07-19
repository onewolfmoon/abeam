// Ports Sources/SignalingCore/Resources/mirror.html + common.js directly —
// that page was already plain browser WebRTC code running inside a
// WKWebView and bridged to native Swift only because Swift owned the
// network connection; here it just talks to ReceiverConnection itself, so
// the callJavaScript bridge disappears entirely rather than needing a port.
//
// No trickle ICE: each side waits for ICE gathering to finish, then hands
// off one self-contained SDP blob over the existing WebSocket connection.
//
// `turnURL` (a "turn:host:port?transport=udp" string, no credentials — see
// TurnServer.swift) is optional: without it, only host candidates are
// gathered. It's what makes Mirror mode work at all from a real Chrome tab
// talking to Screen's WebKit-based receiver.html — Chrome's host ICE
// candidates are mDNS-obfuscated (privacy feature) and WebKit can't resolve
// them, so without a TURN relay candidate (which always carries a literal
// IP) there was no candidate pair either side could ever connect on.

// TurnServer.swift never actually checks these — it's an unauthenticated,
// LAN-only relay — but RTCPeerConnection itself throws synchronously at
// construction time if a turn:/turns: ICE server is given without both
// fields present, regardless of whether the server cares.
const TURN_PLACEHOLDER_CREDENTIAL = "blittie";

export type MirrorConnectionState = RTCPeerConnectionState | "none";

export class MirrorSession {
  private pc: RTCPeerConnection | null = null;
  private localStream: MediaStream | null = null;

  get stream(): MediaStream | null {
    return this.localStream;
  }

  get isCapturing(): boolean {
    return this.localStream !== null;
  }

  get connectionState(): MirrorConnectionState {
    return this.pc?.connectionState ?? "none";
  }

  // Captures the screen and builds a self-contained SDP offer. Throws if the
  // user cancels the screen-share picker or denies permission.
  //
  // `turnURL` may be a Promise: getDisplayMedia must run first, synchronously
  // off the caller's click, or Chrome silently drops the screen-share picker
  // (getDisplayMedia requires "transient user activation," which a network
  // round-trip awaited beforehand is enough to lose) — so the caller starts
  // fetching it in parallel rather than awaiting it before calling here, and
  // it's only resolved below, after getDisplayMedia has already returned.
  async createOffer(onEnded: () => void, turnURL?: string | null | Promise<string | null>): Promise<string> {
    const localStream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    this.localStream = localStream;
    // Also catches the user stopping the share from the OS's own
    // screen-recording control, not just our own Stop button.
    localStream.getVideoTracks()[0].addEventListener("ended", () => {
      this.teardown();
      onEnded();
    });

    const resolvedTurnURL = await turnURL;
    const iceServers = resolvedTurnURL
      ? [{ urls: resolvedTurnURL, username: TURN_PLACEHOLDER_CREDENTIAL, credential: TURN_PLACEHOLDER_CREDENTIAL }]
      : [];
    const pc = new RTCPeerConnection({ iceServers });
    this.pc = pc;
    pc.addEventListener("connectionstatechange", () => {
      if (["disconnected", "failed", "closed"].includes(pc.connectionState)) {
        this.teardown();
        onEnded();
      }
    });
    localStream.getTracks().forEach((track) => pc.addTrack(track, localStream));

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await waitForIceGatheringComplete(pc);

    return JSON.stringify(pc.localDescription);
  }

  async applyAnswer(answerJson: string): Promise<void> {
    if (!this.pc) throw new Error("no offer in progress");
    await this.pc.setRemoteDescription(JSON.parse(answerJson));
  }

  stop(): void {
    this.teardown();
  }

  private teardown(): void {
    this.localStream?.getTracks().forEach((track) => track.stop());
    this.localStream = null;
    this.pc?.close();
    this.pc = null;
  }
}

function waitForIceGatheringComplete(pc: RTCPeerConnection): Promise<void> {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    function check() {
      if (pc.iceGatheringState === "complete") {
        pc.removeEventListener("icegatheringstatechange", check);
        resolve();
      }
    }
    pc.addEventListener("icegatheringstatechange", check);
  });
}
