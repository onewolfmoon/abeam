import { useEffect, useRef, useState } from "react";
import "./App.css";
import { ReceiverConnection } from "./lib/receiverConnection";
import type { ReceiverEndpoint } from "./lib/receiverEndpoint";
import { endpointDisplayName, loadPersistedEndpoint, persistEndpoint } from "./lib/receiverEndpoint";
import { useConnectionState } from "./lib/useConnectionState";
import { StatusBadge } from "./components/StatusBadge";
import { ReceiverAddressDialog } from "./components/ReceiverAddressDialog";
import { SendVideoView } from "./components/SendVideoView";
import { MirrorView } from "./components/MirrorView";
import { ScreenSourcePicker } from "./components/ScreenSourcePicker";

type SenderMode = "video" | "mirror";

const MODES: { id: SenderMode; title: string; icon: string }[] = [
  { id: "video", title: "Send Video", icon: "▶" },
  { id: "mirror", title: "Mirror Screen", icon: "▤" },
];

// Web port of AppModel.swift + ContentView.swift, with Bonjour discovery
// dropped (unavailable to a browser) and manual entry defaulting to the
// Tailscale Serve endpoint (see receiverEndpoint.ts) instead of a raw LAN
// ws:// port.
export default function App() {
  const connection = useRef(new ReceiverConnection()).current;
  const connectionState = useConnectionState(connection);

  const [endpoint, setEndpoint] = useState<ReceiverEndpoint | null>(() => loadPersistedEndpoint());
  const [mode, setMode] = useState<SenderMode>("video");
  const [showDialog, setShowDialog] = useState(false);
  const [pickerSources, setPickerSources] = useState<PickerSource[] | null>(null);

  useEffect(() => {
    if (endpoint) connection.connect(endpoint);
    // Only reconnect on mount / explicit selection, not on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // electron/main.ts intercepts getDisplayMedia() and asks us to show a
  // picker in place of Chrome's native one; see electron/preload.ts.
  useEffect(() => {
    return window.electronAPI.onScreenPickerRequest(setPickerSources);
  }, []);

  function selectEndpoint(next: ReceiverEndpoint) {
    setEndpoint(next);
    persistEndpoint(next);
    connection.connect(next);
    setShowDialog(false);
  }

  const receiverName = endpoint ? endpointDisplayName(endpoint) : null;

  return (
    <div className="app">
      <nav className="sidebar">
        <h1>Blittie Projector</h1>
        <ul className="mode-list">
          {MODES.map((m) => (
            <li key={m.id}>
              <button className={mode === m.id ? "mode-button active" : "mode-button"} onClick={() => setMode(m.id)}>
                <span className="mode-icon" aria-hidden="true">
                  {m.icon}
                </span>
                {m.title}
              </button>
            </li>
          ))}
        </ul>
      </nav>

      <main className="content">
        <header className="toolbar">
          <StatusBadge connectionState={connectionState} receiverName={receiverName} />
          <button className="secondary" onClick={() => setShowDialog(true)}>
            {endpoint ? "Change" : "Choose Screen"}
          </button>
        </header>

        <div className="content-body">
          {!endpoint ? (
            <EmptyState onChoose={() => setShowDialog(true)} />
          ) : mode === "video" ? (
            <SendVideoView connection={connection} />
          ) : (
            <MirrorView connection={connection} receiverName={receiverName!} />
          )}
        </div>
      </main>

      {showDialog && (
        <ReceiverAddressDialog
          currentEndpoint={endpoint}
          onConnect={selectEndpoint}
          onCancel={() => setShowDialog(false)}
        />
      )}

      {pickerSources && (
        <ScreenSourcePicker
          sources={pickerSources}
          onPick={(id) => {
            window.electronAPI.selectScreenSource(id);
            setPickerSources(null);
          }}
          onCancel={() => {
            window.electronAPI.selectScreenSource(null);
            setPickerSources(null);
          }}
        />
      )}
    </div>
  );
}

function EmptyState({ onChoose }: { onChoose: () => void }) {
  return (
    <div className="empty-state">
      <p className="empty-state-title">Choose a Screen to get started</p>
      <button className="primary" onClick={onChoose}>
        Choose Screen
      </button>
    </div>
  );
}
