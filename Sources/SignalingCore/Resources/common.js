// Shared WebRTC signaling helpers.
// LAN-only, no trickle ICE — each side waits for ICE gathering to finish,
// then hands off one self-contained SDP blob over the WebSocket signaling
// channel. `turnURL` (a "turn:host:port?transport=udp" string — see
// TurnServer) is optional: without it, only host candidates are gathered,
// which is all a same-engine pairing ever needed. It matters for a
// Chrome-based Sender talking to this WebKit-based Receiver, since Chrome's
// host candidates are mDNS-obfuscated and unresolvable here — the TURN
// relay candidate is what makes that pairing work at all.

// TurnServer never actually checks these — it's an unauthenticated,
// LAN-only relay (see its file header) — but RTCPeerConnection itself
// throws synchronously at construction time if a turn:/turns: ICE server is
// given without both fields present, regardless of whether the server cares.
const TURN_PLACEHOLDER_CREDENTIAL = 'blittie';

function createPeerConnection(turnURL) {
  const iceServers = turnURL
    ? [{ urls: turnURL, username: TURN_PLACEHOLDER_CREDENTIAL, credential: TURN_PLACEHOLDER_CREDENTIAL }]
    : [];
  return new RTCPeerConnection({ iceServers });
}

function waitForIceGatheringComplete(pc) {
  if (pc.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    function check() {
      if (pc.iceGatheringState === 'complete') {
        pc.removeEventListener('icegatheringstatechange', check);
        resolve();
      }
    }
    pc.addEventListener('icegatheringstatechange', check);
  });
}

function wireConnectionStatus(pc, statusEl) {
  const update = () => {
    statusEl.textContent = `connection: ${pc.connectionState} / ice: ${pc.iceConnectionState}`;
  };
  pc.addEventListener('connectionstatechange', update);
  pc.addEventListener('iceconnectionstatechange', update);
  update();
}
