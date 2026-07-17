import type { RequestPayload, ResponsePayload } from "./wireProtocol";
import { encodeRequest, decodeResponse } from "./wireProtocol";
import type { ReceiverEndpoint } from "./receiverEndpoint";
import { endpointToSocketURL } from "./receiverEndpoint";

// One persistent WebSocket connection to a Screen, shared by every request
// kind (youtube/offer/control/stop) — mirrors
// Sources/ReceiverProtocol/ReceiverConnection.swift's actor. Unlike the
// Swift version (which exposes `state` via polling to sidestep actor
// isolation from a non-actor SwiftUI observer), this exposes it via a plain
// subscribe callback, which is the natural fit for a browser WebSocket.
export type ConnectionState =
  | { kind: "disconnected" }
  | { kind: "connecting" }
  | { kind: "connected" }
  | { kind: "failed"; message: string };

type StateListener = (state: ConnectionState) => void;

function sameEndpoint(a: ReceiverEndpoint, b: ReceiverEndpoint): boolean {
  return a.scheme === b.scheme && a.host === b.host && a.port === b.port;
}

export class NotConnectedError extends Error {
  constructor() {
    super("not connected to a Screen instance");
    this.name = "NotConnectedError";
  }
}

export class ReceiverRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReceiverRequestError";
  }
}

export class ReceiverConnection {
  private socket: WebSocket | null = null;
  private endpoint: ReceiverEndpoint | null = null;
  private shouldReconnect = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pending = new Map<
    string,
    { resolve: (payload: ResponsePayload) => void; reject: (error: Error) => void }
  >();
  private listeners = new Set<StateListener>();
  private currentState: ConnectionState = { kind: "disconnected" };

  get state(): ConnectionState {
    return this.currentState;
  }

  subscribe(listener: StateListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  connect(endpoint: ReceiverEndpoint): void {
    if (
      this.endpoint &&
      sameEndpoint(this.endpoint, endpoint) &&
      (this.currentState.kind === "connecting" || this.currentState.kind === "connected")
    ) {
      return;
    }
    this.endpoint = endpoint;
    this.shouldReconnect = true;
    this.reconnectAttempt = 0;
    this.clearReconnectTimer();
    this.socket?.close();
    this.open();
  }

  disconnect(): void {
    this.shouldReconnect = false;
    this.endpoint = null;
    this.clearReconnectTimer();
    this.socket?.close();
    this.socket = null;
    this.setState({ kind: "disconnected" });
    this.failAllPending(new NotConnectedError());
  }

  async send(payload: RequestPayload): Promise<ResponsePayload> {
    if (!this.socket || this.currentState.kind !== "connected") {
      throw new NotConnectedError();
    }
    const { id, json } = encodeRequest(payload);
    return new Promise<ResponsePayload>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try {
        this.socket!.send(json);
      } catch (error) {
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private open(): void {
    if (!this.endpoint) return;
    this.setState({ kind: "connecting" });
    const socket = new WebSocket(endpointToSocketURL(this.endpoint));
    this.socket = socket;

    socket.onopen = () => {
      this.reconnectAttempt = 0;
      this.setState({ kind: "connected" });
    };
    socket.onmessage = (event) => {
      if (typeof event.data === "string") this.handleIncoming(event.data);
    };
    socket.onclose = (event) => {
      if (this.socket !== socket) return; // stale handler from a superseded socket
      this.failAllPending(new NotConnectedError());
      if (this.shouldReconnect) {
        this.setState({ kind: "failed", message: event.reason || `connection closed (code ${event.code})` });
        this.scheduleReconnect();
      } else {
        this.setState({ kind: "disconnected" });
      }
    };
    // The close event above already carries the failure reason; no separate
    // handling needed here beyond letting it fire.
    socket.onerror = () => {};
  }

  private handleIncoming(data: string): void {
    const response = decodeResponse(data);
    if (!response) return;
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    pending.resolve(response.payload);
  }

  // Capped, linearly-increasing backoff, matching ReceiverConnection.swift:
  // a dropped LAN/Tailscale connection is usually transient, so retry
  // promptly at first without hammering the network indefinitely.
  private scheduleReconnect(): void {
    if (!this.shouldReconnect || !this.endpoint) return;
    this.reconnectAttempt += 1;
    const delayMs = Math.min(this.reconnectAttempt * 1.5, 15) * 1000;
    this.clearReconnectTimer();
    this.reconnectTimer = setTimeout(() => {
      if (this.shouldReconnect) this.open();
    }, delayMs);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private setState(state: ConnectionState): void {
    this.currentState = state;
    for (const listener of this.listeners) listener(state);
  }

  private failAllPending(error: Error): void {
    const all = Array.from(this.pending.values());
    this.pending.clear();
    for (const p of all) p.reject(error);
  }
}

// Thin wrappers over ReceiverConnection.send, matching the AppModel.swift
// extension of the same name.
export async function sendYouTube(connection: ReceiverConnection, url: string): Promise<boolean> {
  const response = await connection.send({ type: "youtube", url });
  switch (response.type) {
    case "ok":
      return true;
    case "error":
      throw new ReceiverRequestError(response.message);
    default:
      return false;
  }
}

export async function sendControl(
  connection: ReceiverConnection,
  control: "playPause" | "seekBack" | "seekForward"
): Promise<boolean> {
  const response = await connection.send({ type: "control", control });
  switch (response.type) {
    case "ok":
      return true;
    case "notHandled":
      return false;
    case "error":
      throw new ReceiverRequestError(response.message);
    default:
      return false;
  }
}

export async function sendStop(connection: ReceiverConnection): Promise<boolean> {
  const response = await connection.send({ type: "stop" });
  switch (response.type) {
    case "ok":
      return true;
    case "notHandled":
      return false;
    case "error":
      throw new ReceiverRequestError(response.message);
    default:
      return false;
  }
}

// Used by the mirror flow: sends the locally-created SDP offer and returns
// the Screen's SDP answer.
export async function sendOffer(connection: ReceiverConnection, sdp: string): Promise<string> {
  const response = await connection.send({ type: "offer", sdp });
  switch (response.type) {
    case "answer":
      return response.sdp;
    case "error":
      throw new ReceiverRequestError(response.message);
    default:
      throw new ReceiverRequestError("Screen did not return an answer");
  }
}
