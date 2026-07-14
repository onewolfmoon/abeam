import Foundation

// Mirrors the JSON shape of a JS RTCSessionDescription
// (`JSON.stringify(pc.localDescription)` on the Receiver's side): a bare
// {"type": "offer"|"answer", "sdp": "..."} object, no envelope. Keeping this
// exact shape is what lets the iOS Sender and Receiver's browser-based
// RTCPeerConnection speak the same wire format.
public struct SessionDescriptionMessage: Codable, Sendable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}
