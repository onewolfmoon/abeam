// Shared WebRTC signaling helpers.
// LAN-only: no STUN/TURN servers, and no trickle ICE — each side waits for
// ICE gathering to finish, then hands off one self-contained SDP blob
// (with all host candidates already embedded) over HTTP.

function createPeerConnection() {
  return new RTCPeerConnection({ iceServers: [] });
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
