// Ports Sources/SignalingCore/Resources/mirror.html + common.js directly —
// that page was already plain browser WebRTC code running inside a
// WKWebView and bridged to native Swift only because Swift owned the
// network connection; here it just talks to ReceiverConnection itself, so
// the callJavaScript bridge disappears entirely rather than needing a port.
//
// LAN-only, no STUN/TURN, no trickle ICE: each side waits for ICE gathering
// to finish, then hands off one self-contained SDP blob (all host
// candidates already embedded) over the existing WebSocket connection.
//
// Known limitation: a browser's host ICE candidates are mDNS-obfuscated
// (privacy feature) and only resolve within the same multicast/LAN segment.
// Mirror mode will reliably connect when the browser and Screen share a
// physical LAN; over a routed-only path (e.g. Tailscale from a different
// network) the mDNS names won't resolve and ICE will stall with no
// fallback, since there's deliberately no STUN/TURN server configured here
// (matches the original's LAN-only trust model). Send Video mode is
// unaffected — it doesn't use WebRTC.

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
  async createOffer(onEnded: () => void): Promise<string> {
    const localStream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    this.localStream = localStream;
    // Also catches the user stopping the share from the OS's own
    // screen-recording control, not just our own Stop button.
    localStream.getVideoTracks()[0].addEventListener("ended", () => {
      this.teardown();
      onEnded();
    });

    const pc = new RTCPeerConnection({ iceServers: [] });
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

    // Temporary: Chrome hides its mDNS-obfuscated candidate address even
    // from webrtc-internals' own stats tables, so this is the only way to
    // recover the literal <uuid>.local name for testing whether it resolves
    // at all outside libwebrtc's own ICE resolver (e.g. `ping` or a direct
    // Safari navigation on the Screen machine). Safe to remove once that's
    // answered — the SDP itself isn't sensitive, it's already being sent to
    // Screen over the WebSocket regardless.
    console.log("[mirror] local SDP:\n" + pc.localDescription?.sdp);

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
