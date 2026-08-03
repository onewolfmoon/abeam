import Foundation

// The JSON envelope carried by every WebSocket text frame between Sender and
// Receiver. One request -> one response, correlated by `id`, since multiple
// requests can now be in flight on the same persistent connection (unlike
// the old one-TCP-connection-per-HTTP-call model, where the response was
// always unambiguous).

public struct ReceiverRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let payload: RequestPayload

    public init(id: UUID = UUID(), payload: RequestPayload) {
        self.id = id
        self.payload = payload
    }
}

public enum RequestPayload: Sendable, Equatable {
    /// Raw share text from the sending app — a bare URL, or freeform text
    /// with a URL embedded in it (e.g. "I'm watching X on Y\nhttps://...").
    /// The receiver is responsible for figuring out which video provider,
    /// if any, this came from.
    case video(payload: String)
    case offer(sdp: String)
    case control(ReceiverControl)
    case stop
}

public enum ReceiverControl: String, Codable, Sendable {
    case playPause
    case seekBack
    case seekForward
}

public struct ReceiverResponse: Codable, Sendable, Equatable {
    public let id: UUID
    public let payload: ResponsePayload

    public init(id: UUID, payload: ResponsePayload) {
        self.id = id
        self.payload = payload
    }
}

public enum ResponsePayload: Sendable, Equatable {
    case ok
    case answer(sdp: String)
    case error(message: String)
    // Mirrors the old 409: no active session for a control/stop to apply to.
    case notHandled
}

// Hand-written rather than relying on associated-value enum synthesis, so the
// wire shape (a `type` discriminator plus the relevant fields) is explicit
// and stable.

extension RequestPayload: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload, sdp, control }
    private enum Kind: String, Codable { case video, offer, control, stop }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .video:
            self = .video(payload: try container.decode(String.self, forKey: .payload))
        case .offer:
            self = .offer(sdp: try container.decode(String.self, forKey: .sdp))
        case .control:
            self = .control(try container.decode(ReceiverControl.self, forKey: .control))
        case .stop:
            self = .stop
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let payload):
            try container.encode(Kind.video, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .offer(let sdp):
            try container.encode(Kind.offer, forKey: .type)
            try container.encode(sdp, forKey: .sdp)
        case .control(let control):
            try container.encode(Kind.control, forKey: .type)
            try container.encode(control, forKey: .control)
        case .stop:
            try container.encode(Kind.stop, forKey: .type)
        }
    }
}

extension ResponsePayload: Codable {
    private enum CodingKeys: String, CodingKey { case type, sdp, message }
    private enum Kind: String, Codable { case ok, answer, error, notHandled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ok:
            self = .ok
        case .answer:
            self = .answer(sdp: try container.decode(String.self, forKey: .sdp))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        case .notHandled:
            self = .notHandled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(Kind.ok, forKey: .type)
        case .answer(let sdp):
            try container.encode(Kind.answer, forKey: .type)
            try container.encode(sdp, forKey: .sdp)
        case .error(let message):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(message, forKey: .message)
        case .notHandled:
            try container.encode(Kind.notHandled, forKey: .type)
        }
    }
}
