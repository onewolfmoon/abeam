// How a Screen instance is identified from the Projector. There's no
// Bonjour/mDNS discovery wired up yet, so this is manual-entry only (see
// Sources/ReceiverProtocol/ReceiverEndpoint.swift for the native
// Bonjour+manual union this replaces).
//
// The expected address is Screen's own host (LAN IP, .local hostname, or a
// Tailscale MagicDNS name — anything reachable) on its plain ws://
// listener, ReceiverEndpoint.defaultPort (see the Swift side). Running as
// Electron rather than a browser page means there's no secure-context
// requirement forcing TLS here, so this connects over plain ws:// by
// default and Screen's self-signed wss:// listener (and the
// certificate-warning click-through it used to require) is no longer
// needed. An explicit wss:// prefix is still accepted if you want to point
// at that listener anyway.

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
// pair, or either with an explicit ws://\wss:// prefix. Defaults to ws on
// 8787 (Screen's plain listener) when no scheme is given.
export function parseManualInput(input: string): ReceiverEndpoint | null {
  let rest = input.trim();
  if (!rest) return null;

  let scheme: "ws" | "wss" = "ws";
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
  const schemePrefix = endpoint.scheme === "wss" ? "wss://" : "";
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
