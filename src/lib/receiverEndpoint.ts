// How a Screen instance is identified from the web Projector. There's no
// Bonjour/mDNS discovery available to a browser, so this is manual-entry
// only (see Sources/ReceiverProtocol/ReceiverEndpoint.swift for the native
// Bonjour+manual union this replaces).
//
// The expected address is Screen's own host (LAN IP, .local hostname, or a
// Tailscale MagicDNS name — anything reachable) on its wss:// listener,
// ReceiverEndpoint.defaultWSSPort (see the Swift side), which terminates TLS
// itself with a self-signed identity rather than going through a separate
// proxy. Each browser/device needs to visit https://<host>:8788 once and
// click through the certificate warning before a WebSocket connection to it
// will succeed — there's no CA involved, so there's nothing to silently
// trust automatically. An explicit ws:// prefix is still accepted for local
// testing directly against Screen's plain ws://:8787 listener.

export interface ReceiverEndpoint {
  scheme: "ws" | "wss";
  host: string;
  port: number;
}

// Mirrors ReceiverEndpoint.defaultPort / .defaultWSSPort in
// Sources/ReceiverProtocol/ReceiverEndpoint.swift.
const DEFAULT_WSS_PORT = 8788;
const DEFAULT_WS_PORT = 8787;
const STORAGE_KEY = "blittieReceiverAddress";

function defaultPortFor(scheme: "ws" | "wss"): number {
  return scheme === "wss" ? DEFAULT_WSS_PORT : DEFAULT_WS_PORT;
}

// Accepts a bare host ("autosvcacct.local" or "192.168.1.110"), a host:port
// pair, or either with an explicit ws://\wss:// prefix. Defaults to wss on
// 8788 (Screen's self-signed listener) when no scheme is given.
export function parseManualInput(input: string): ReceiverEndpoint | null {
  let rest = input.trim();
  if (!rest) return null;

  let scheme: "ws" | "wss" = "wss";
  if (rest.toLowerCase().startsWith("wss://")) {
    scheme = "wss";
    rest = rest.slice(6);
  } else if (rest.toLowerCase().startsWith("ws://")) {
    scheme = "ws";
    rest = rest.slice(5);
  }
  rest = rest.replace(/\/+$/, "");

  if (!/^[a-zA-Z0-9.-]+(:\d+)?$/.test(rest)) return null;

  const lastColon = rest.lastIndexOf(":");
  let host: string;
  let port: number;
  if (lastColon !== -1) {
    host = rest.slice(0, lastColon);
    port = Number(rest.slice(lastColon + 1));
  } else {
    host = rest;
    port = defaultPortFor(scheme);
  }
  if (!host) return null;
  return { scheme, host, port };
}

export function endpointToSocketURL(endpoint: ReceiverEndpoint): string {
  return `${endpoint.scheme}://${endpoint.host}:${endpoint.port}/`;
}

export function endpointDisplayName(endpoint: ReceiverEndpoint): string {
  const portSuffix = endpoint.port === defaultPortFor(endpoint.scheme) ? "" : `:${endpoint.port}`;
  const schemePrefix = endpoint.scheme === "ws" ? "ws://" : "";
  return `${schemePrefix}${endpoint.host}${portSuffix}`;
}

export function loadPersistedEndpoint(): ReceiverEndpoint | null {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (
      parsed &&
      (parsed.scheme === "ws" || parsed.scheme === "wss") &&
      typeof parsed.host === "string" &&
      typeof parsed.port === "number"
    ) {
      return { scheme: parsed.scheme, host: parsed.host, port: parsed.port };
    }
  } catch {
    // fall through
  }
  return null;
}

export function persistEndpoint(endpoint: ReceiverEndpoint): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(endpoint));
}
