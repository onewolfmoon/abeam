import { useState } from "react";
import type { ReceiverConnection } from "../lib/receiverConnection";
import { sendControl, sendStop, sendYouTube } from "../lib/receiverConnection";

// Direct port of SendVideoView.swift.
export function SendVideoView({ connection }: { connection: ReceiverConnection }) {
  const [urlText, setUrlText] = useState("");
  const [isSending, setIsSending] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);

  async function send() {
    const url = urlText.trim();
    if (!url) return;
    setIsSending(true);
    setStatusMessage("sending to Screen…");
    try {
      await sendYouTube(connection, url);
      setStatusMessage("Screen is playing the video");
      setUrlText("");
    } catch (error) {
      setStatusMessage(`error: ${(error as Error).message}`);
    } finally {
      setIsSending(false);
    }
  }

  async function control(kind: "playPause" | "seekBack" | "seekForward") {
    try {
      const handled = await sendControl(connection, kind);
      if (!handled) setStatusMessage("nothing is playing right now");
    } catch (error) {
      setStatusMessage(`error: ${(error as Error).message}`);
    }
  }

  async function stop() {
    try {
      const handled = await sendStop(connection);
      if (!handled) setStatusMessage("nothing is playing right now");
    } catch (error) {
      setStatusMessage(`error: ${(error as Error).message}`);
    }
  }

  return (
    <div className="send-video-view">
      <section className="panel">
        <h3>Video URL</h3>
        <div className="dialog-row">
          <input
            type="text"
            value={urlText}
            placeholder="https://example.com/video.mp4"
            onChange={(e) => setUrlText(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && send()}
          />
          <button className="primary" onClick={send} disabled={urlText.trim().length === 0 || isSending}>
            Send
          </button>
        </div>
      </section>

      <section className="panel">
        <h3>Playback Controls</h3>
        <div className="control-row">
          <button className="round" title="Seek Back 5 Seconds" onClick={() => control("seekBack")}>
            ⏪
          </button>
          <button className="round primary large" title="Play/Pause" onClick={() => control("playPause")}>
            ⏯
          </button>
          <button className="round" title="Seek Forward 5 Seconds" onClick={() => control("seekForward")}>
            ⏩
          </button>
          <button className="round" title="Stop" onClick={stop}>
            ⏹
          </button>
        </div>
      </section>

      {statusMessage && <p className="status-message">{statusMessage}</p>}
    </div>
  );
}
