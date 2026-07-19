// Ports Sources/SignalingCore/Resources/mirror.html + common.js directly —
// that page was already plain browser WebRTC code running inside a
// WKWebView and bridged to native Swift only because Swift owned the
// network connection; here it just talks to ReceiverConnection itself, so
// the callJavaScript bridge disappears entirely rather than needing a port.
//
// No STUN/TURN, no trickle ICE: each side waits for ICE gathering to
// finish, then hands off one self-contained SDP blob (all host candidates
// already embedded) over the existing WebSocket connection. This matches
// Screen's current WireProtocol.swift/ReceiverSocketServer.swift, which no
// longer has a TURN relay or iceConfig request at all (removed once it
// became unnecessary — see below) — an unrecognized request type there is
// silently dropped with no response, so this side must never send one.
//
// Known limitation: without a TURN relay, this only works when there's a
// real routable path between Sender and Screen at the IP level (a shared
// LAN, or same-tailnet Tailscale) — genuine NAT traversal (e.g. across the
// open internet without Tailscale) has no fallback. This used to also fail
// on a plain LAN, because Chrome obfuscates its own host ICE candidates
// behind a random <uuid>.local mDNS name that Screen's WebKit-based
// receiver never resolves (see reports/mirror-mode-mdns-findings.md) — but
// running as Electron rather than a browser page means this Sender can
// (and does, in electron/main.ts) disable that obfuscation directly, which
// is what let Screen drop the TURN workaround entirely.

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
