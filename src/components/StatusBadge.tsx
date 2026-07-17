import type { ConnectionState } from "../lib/receiverConnection";

// Mirrors ReceiverStatusLabel in ContentView.swift: a colored dot plus text,
// reflecting the live WebSocket state rather than just "an address is
// saved".
export function StatusBadge({
  connectionState,
  receiverName,
}: {
  connectionState: ConnectionState;
  receiverName: string | null;
}) {
  const color = statusColor(connectionState);
  const label = receiverName === null ? "No Screen selected" : statusText(connectionState, receiverName);

  return (
    <div className="status-badge" role="status" aria-label={label}>
      <span className="status-dot" style={{ backgroundColor: color }} aria-hidden="true" />
      <span className="status-text">{label}</span>
    </div>
  );
}

function statusColor(state: ConnectionState): string {
  switch (state.kind) {
    case "connected":
      return "#34c759";
    case "connecting":
      return "#ffcc00";
    case "failed":
      return "#ff3b30";
    case "disconnected":
      return "rgba(128, 128, 128, 0.4)";
  }
}

function statusText(state: ConnectionState, receiverName: string): string {
  switch (state.kind) {
    case "connected":
      return `Connected to ${receiverName}`;
    case "connecting":
      return `Connecting to ${receiverName}`;
    case "failed":
      return `Connection to ${receiverName} failed`;
    case "disconnected":
      return `Disconnected from ${receiverName}`;
  }
}
