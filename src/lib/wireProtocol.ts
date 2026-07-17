// Mirrors Sources/ReceiverProtocol/WireProtocol.swift's JSON envelope exactly:
// { id, payload: { type, ...fields } } in both directions, one request -> one
// response correlated by id. Kept as a hand-written discriminated union
// (rather than deriving types from schema) so the wire shape stays an
// explicit, obvious match for the Swift Codable implementation it talks to.

export type ReceiverControl = "playPause" | "seekBack" | "seekForward";

export type RequestPayload =
  | { type: "youtube"; url: string }
  | { type: "offer"; sdp: string }
  | { type: "control"; control: ReceiverControl }
  | { type: "stop" };

export type ResponsePayload =
  | { type: "ok" }
  | { type: "answer"; sdp: string }
  | { type: "error"; message: string }
  // Mirrors the old 409: no active session for a control/stop to apply to.
  | { type: "notHandled" };

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
// lowercase. Foundation's UUID(uuidString:) parses either case, so no
// normalization is needed on either side of the wire.
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
