// Mirrors Sources/ReceiverProtocol/WireProtocol.swift's JSON envelope exactly:
// { id, payload: { type, ...fields } } in both directions, one request -> one
// response correlated by id. Kept as a hand-written discriminated union
// (rather than deriving types from schema) so the wire shape stays an
// explicit, obvious match for the Swift Codable implementation it talks to.

export type ReceiverControl = "playPause" | "seekBack" | "seekForward";

export type RequestPayload =
  // Raw share text (a bare URL, or freeform text with a URL embedded in
  // it, e.g. Dropout's "I'm watching X on Dropout\nhttps://...") — Screen's
  // VideoParserRegistry is responsible for recognizing the provider, this
  // side does no interpretation. Was `{ type: "youtube"; url }` back when
  // Screen only played YouTube; see jj change ruvsvwto in ../vga.
  | { type: "video"; payload: string }
  | { type: "offer"; sdp: string }
  | { type: "control"; control: ReceiverControl }
  | { type: "stop" }
  // Asks Screen for the TURN relay to use when building an SDP offer —
  // needed because Chrome's host ICE candidates are mDNS-obfuscated and
  // unresolvable by Screen's WebKit-based receiver.html; see TurnServer.swift.
  | { type: "iceConfig" };

export type ResponsePayload =
  | { type: "ok" }
  | { type: "answer"; sdp: string }
  | { type: "error"; message: string }
  // Mirrors the old 409: no active session for a control/stop to apply to.
  | { type: "notHandled" }
  // A "turn:host:port?transport=udp" URL, no credentials (LAN-only, no
  // auth — same trust model as the rest of this protocol).
  | { type: "iceConfig"; turnURL: string };

export interface ReceiverRequest {
  id: string;
  payload: RequestPayload;
}

export interface ReceiverResponse {
  id: string;
  payload: ResponsePayload;
}

export function encodeRequest(payload: RequestPayload): { id: string; json: string } {
  const id = crypto.randomUUID();
  const request: ReceiverRequest = { id, payload };
  return { id, json: JSON.stringify(request) };
}

// Swift's UUID JSON representation is uppercase; JS's crypto.randomUUID() is
// lowercase. Foundation's UUID(uuidString:) parses incoming requests
// case-insensitively either way, but it always *re-serializes* a response's
// id canonically uppercase regardless of the request's original casing — so
// the two are never a byte-for-byte match on the way back. This decode step
// only validates shape; ReceiverConnection.handleIncoming is what actually
// lowercases response.id before matching it against `pending`.
export function decodeResponse(data: string): ReceiverResponse | null {
  try {
    const parsed = JSON.parse(data);
    if (
      parsed &&
      typeof parsed.id === "string" &&
      parsed.payload &&
      typeof parsed.payload.type === "string"
    ) {
      return parsed as ReceiverResponse;
    }
  } catch {
    // fall through
  }
  return null;
}
