// Shared WebRTC signaling helpers.
// LAN-only: no STUN/TURN servers, and no trickle ICE — each side waits for
// ICE gathering to finish, then hands off one self-contained SDP blob
// (with all host candidates already embedded) via copy/paste.

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

function wireCopyButton(buttonEl, textareaEl) {
  textareaEl.addEventListener('click', () => textareaEl.select());
  buttonEl.addEventListener('click', async () => {
    textareaEl.select();
    try {
      await navigator.clipboard.writeText(textareaEl.value);
    } catch (e) {
      document.execCommand('copy');
    }
    const original = buttonEl.textContent;
    buttonEl.textContent = 'Copied!';
    setTimeout(() => { buttonEl.textContent = original; }, 1200);
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

// Lets native Swift code poll connection state via callJavaScript, since
// that's the confirmed-working Swift<->JS bridge in the new WebKit-for-SwiftUI
// API (unlike JS->Swift push messaging, which this project doesn't rely on).
window.__vgaConnectionState = () => 'none';

function exposeConnectionState(pc) {
  window.__vgaConnectionState = () => pc.connectionState;
}
