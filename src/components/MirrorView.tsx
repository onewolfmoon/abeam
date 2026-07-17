import { useEffect, useRef, useState } from "react";
import type { ReceiverConnection } from "../lib/receiverConnection";
import { sendOffer } from "../lib/receiverConnection";
import { MirrorSession } from "../lib/mirrorSession";

// Port of MirrorView.swift + mirror.html/common.js. The native version ran
// this WebRTC logic inside a WKWebView and bridged it to Swift only because
// Swift owned the network connection — here it talks to ReceiverConnection
// directly, and RTCPeerConnection's own connectionstatechange event replaces
// the native version's poll-based watchForExternalStop.
export function MirrorView({ connection, receiverName }: { connection: ReceiverConnection; receiverName: string }) {
  const sessionRef = useRef<MirrorSession>(new MirrorSession());
  const videoRef = useRef<HTMLVideoElement | null>(null);

  // isCapturing tracks local preview visibility from the moment
  // getDisplayMedia succeeds; isMirroring tracks the full handshake (offer
  // sent, answer applied) and gates the "Mirroring to X · mm:ss" status text.
  // Kept separate so the local preview appears immediately on capture start,
  // matching mirror.html's own independent 'active' class toggle rather than
  // waiting on the Screen round-trip.
  const [isCapturing, setIsCapturing] = useState(false);
  const [isMirroring, setIsMirroring] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [startedAt, setStartedAt] = useState<number | null>(null);
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    if (!isMirroring) return;
    const interval = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(interval);
  }, [isMirroring]);

  // Leaving Mirror mode (component unmount) stops any in-progress capture,
  // matching MirrorView.swift's onDisappear.
  useEffect(() => {
    return () => {
      sessionRef.current.stop();
    };
  }, []);

  function handleExternalStop() {
    setIsCapturing(false);
    setIsMirroring(false);
    setStartedAt(null);
    setStatusMessage(null);
    if (videoRef.current) videoRef.current.srcObject = null;
  }

  async function start() {
    const session = sessionRef.current;
    setStatusMessage("requesting screen share…");
    try {
      const offer = await session.createOffer(handleExternalStop);
      if (videoRef.current) videoRef.current.srcObject = session.stream;
      setIsCapturing(true);

      setStatusMessage("connecting to Screen…");
      const answer = await sendOffer(connection, offer);
      await session.applyAnswer(answer);

      setStatusMessage(null);
      setStartedAt(Date.now());
      setIsMirroring(true);
    } catch (error) {
      setStatusMessage(`error: ${(error as Error).message}`);
      setIsCapturing(false);
      session.stop();
    }
  }

  function stop() {
    sessionRef.current.stop();
    if (videoRef.current) videoRef.current.srcObject = null;
    setIsCapturing(false);
    setIsMirroring(false);
    setStartedAt(null);
    setStatusMessage(null);
  }

  const statusText = (() => {
    if (statusMessage) return statusMessage;
    if (!isMirroring || startedAt === null) return "Not mirroring";
    const elapsed = Math.floor((now - startedAt) / 1000);
    const minutes = String(Math.floor(elapsed / 60)).padStart(2, "0");
    const seconds = String(elapsed % 60).padStart(2, "0");
    return `Mirroring to ${receiverName} · ${minutes}:${seconds}`;
  })();

  return (
    <div className="mirror-view">
      <div className="mirror-preview">
        <video ref={videoRef} autoPlay playsInline muted className={isCapturing ? "active" : ""} />
      </div>
      <div className="mirror-status-bar">
        <span
          className="status-dot"
          style={{ backgroundColor: isMirroring ? "#34c759" : "rgba(128, 128, 128, 0.4)" }}
          aria-hidden="true"
        />
        <span className="status-text">{statusText}</span>
        <div className="spacer" />
        <button className={isMirroring ? "danger" : "primary"} onClick={isMirroring ? stop : start}>
          {isMirroring ? "Stop Mirroring" : "Start Mirroring"}
        </button>
      </div>
    </div>
  );
}
