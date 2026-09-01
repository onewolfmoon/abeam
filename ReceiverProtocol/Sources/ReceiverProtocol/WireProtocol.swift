import Foundation

/// The shape of the JSON object representing WebSocket messages between Abeam
/// and Abaft.
public struct ReceiverRequest: Codable, Sendable, Equatable {
    /// A way to match messages with their responses.
    public let id: UUID
    public let payload: RequestPayload

    public init(id: UUID = UUID(), payload: RequestPayload) {
        self.id = id
        self.payload = payload
    }
}

public enum RequestPayload: Sendable, Equatable {
    /// The `payload` argument represents the share payload. If the URL only
    /// makes up part of the payload, Abaft will parse it on the receiving side.
    case video(payload: String)
    case offer(sdp: String)
    case control(ReceiverControl)
    case stop
    /// Turns on the receiver's display.
    case displayOn
    /// Stops any active session and turns off the receiver's display.
    case displayOff
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
    /// No active session for a control/stop to apply to.
    case notHandled
}

/// An extension that handles using `type` as a discriminator.
extension RequestPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, payload, sdp, control
    }
    private enum Kind: String, Codable {
        case video, offer, control, stop, displayOn, displayOff
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .video:
            self = .video(
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .offer:
            self = .offer(sdp: try container.decode(String.self, forKey: .sdp))
        case .control:
            self = .control(
                try container.decode(ReceiverControl.self, forKey: .control)
            )
        case .stop:
            self = .stop
        case .displayOn:
            self = .displayOn
        case .displayOff:
            self = .displayOff
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
        case .displayOn:
            try container.encode(Kind.displayOn, forKey: .type)
        case .displayOff:
            try container.encode(Kind.displayOff, forKey: .type)
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
            self = .error(
                message: try container.decode(String.self, forKey: .message)
            )
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
