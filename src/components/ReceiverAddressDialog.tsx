import { useEffect, useState } from "react";
import type { ReceiverEndpoint } from "../lib/receiverEndpoint";
import { endpointDisplayName, parseManualInput } from "../lib/receiverEndpoint";

// Ports ReceiverPickerSheet.swift's "On Your Network" list back on top of
// the manual-entry flow — Electron's main process can do real mDNS browsing
// (electron/main.ts), unlike the browser-only version this replaced.
export function ReceiverAddressDialog({
  currentEndpoint,
  onConnect,
  onCancel,
}: {
  currentEndpoint: ReceiverEndpoint | null;
  onConnect: (endpoint: ReceiverEndpoint) => void;
  onCancel: () => void;
}) {
  const [address, setAddress] = useState(currentEndpoint ? endpointDisplayName(currentEndpoint) : "");
  const [error, setError] = useState<string | null>(null);
  const [discovered, setDiscovered] = useState<DiscoveredScreen[]>([]);

  useEffect(() => {
    window.electronAPI.getDiscoveredScreens().then(setDiscovered);
    return window.electronAPI.onDiscoveredScreensChanged(setDiscovered);
  }, []);

  function connect() {
    const endpoint = parseManualInput(address);
    if (!endpoint) {
      setError("Enter Screen's address (e.g. autosvcacct.local) or host:port.");
      return;
    }
    onConnect(endpoint);
  }

  function connectToDiscovered(screen: DiscoveredScreen) {
    onConnect({ scheme: "ws", host: screen.host, port: screen.port });
  }

  return (
    <div className="dialog-overlay" role="presentation" onClick={onCancel}>
      <div className="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title" onClick={(e) => e.stopPropagation()}>
        <h2 id="dialog-title">Choose a Blittie Screen</h2>

        {discovered.length > 0 && (
          <>
            <p className="dialog-section-label">On Your Network</p>
            <ul className="discovered-list">
              {discovered.map((screen) => (
                <li key={screen.id}>
                  <button className="discovered-item" onClick={() => connectToDiscovered(screen)}>
                    {screen.name}
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}

        <p className="dialog-hint">
          Enter the Screen's address (its own <code>ws://</code> listener, port 8787 by default) — a LAN IP, a
          <code>.local</code> hostname, or a Tailscale MagicDNS name.
        </p>
        <div className="dialog-row">
          <input
            type="text"
            value={address}
            placeholder="autosvcacct.local"
            autoFocus
            onChange={(e) => setAddress(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") connect();
              if (e.key === "Escape") onCancel();
            }}
          />
          <button className="primary" onClick={connect} disabled={address.trim().length === 0}>
            Connect
          </button>
        </div>
        {error && <p className="dialog-error">{error}</p>}
        <div className="dialog-actions">
          <button onClick={onCancel}>Cancel</button>
        </div>
      </div>
    </div>
  );
}
