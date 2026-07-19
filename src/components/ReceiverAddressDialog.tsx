import { useState } from "react";
import type { ReceiverEndpoint } from "../lib/receiverEndpoint";
import { endpointDisplayName, parseManualInput } from "../lib/receiverEndpoint";

// Manual-entry-only version of ReceiverPickerSheet.swift — no Bonjour
// browsing is available from a browser, so this drops the "On Your Network"
// list entirely and keeps only the "enter an address" flow.
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

  function connect() {
    const endpoint = parseManualInput(address);
    if (!endpoint) {
      setError("Enter Screen's address (e.g. autosvcacct.local) or host:port.");
      return;
    }
    onConnect(endpoint);
  }

  return (
    <div className="dialog-overlay" role="presentation" onClick={onCancel}>
      <div className="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title" onClick={(e) => e.stopPropagation()}>
        <h2 id="dialog-title">Choose a Blittie Screen</h2>
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
