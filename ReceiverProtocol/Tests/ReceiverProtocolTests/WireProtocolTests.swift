import Foundation
import Testing

@testable import ReceiverProtocol

/// Round-trip tests for `RequestPayload`/`ResponsePayload` and their wrapping
/// `ReceiverRequest`/`ReceiverResponse` envelopes.
struct WireProtocolTests {

    // MARK: - RequestPayload round trips

    @Test func videoRequestRoundTrips() throws {
        try assertRoundTrips(RequestPayload.video(payload: "https://youtu.be/abc123"))
    }

    @Test func offerRequestRoundTrips() throws {
        try assertRoundTrips(RequestPayload.offer(sdp: "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"))
    }

    @Test(arguments: [
        ReceiverControl.playPause, .seekBack, .seekForward,
    ])
    func controlRequestRoundTrips(_ control: ReceiverControl) throws {
        try assertRoundTrips(RequestPayload.control(control))
    }

    @Test func stopRequestRoundTrips() throws {
        try assertRoundTrips(RequestPayload.stop)
    }

    @Test func displayOnRequestRoundTrips() throws {
        try assertRoundTrips(RequestPayload.displayOn)
    }

    @Test func displayOffRequestRoundTrips() throws {
        try assertRoundTrips(RequestPayload.displayOff)
    }

    @Test func receiverRequestRoundTrips() throws {
        let request = ReceiverRequest(payload: .video(payload: "https://example.com"))
        let decoded = try roundTrip(request, as: ReceiverRequest.self)
        #expect(decoded == request)
    }

    // MARK: - ResponsePayload round trips

    @Test func okResponseRoundTrips() throws {
        try assertRoundTrips(ResponsePayload.ok)
    }

    @Test func answerResponseRoundTrips() throws {
        try assertRoundTrips(ResponsePayload.answer(sdp: "v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\n"))
    }

    @Test func errorResponseRoundTrips() throws {
        try assertRoundTrips(ResponsePayload.error(message: "Something went wrong."))
    }

    @Test func notHandledResponseRoundTrips() throws {
        try assertRoundTrips(ResponsePayload.notHandled)
    }

    @Test func receiverResponseRoundTrips() throws {
        let response = ReceiverResponse(id: UUID(), payload: .answer(sdp: "v=0"))
        let decoded = try roundTrip(response, as: ReceiverResponse.self)
        #expect(decoded == response)
    }

    // MARK: - Fixed-format decode tests
    //
    // These decode a literal JSON string rather than something this package
    // just encoded, so they fail if the `type` discriminator or a field name
    // ever changes -- protecting compatibility with whatever's on the wire
    // even if both sides of a round trip happen to still agree with each
    // other.

    @Test func decodesVideoRequestFromFixedJSON() throws {
        let json = """
            {"type":"video","payload":"https://example.com/watch"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .video(payload: "https://example.com/watch"))
    }

    @Test func decodesOfferRequestFromFixedJSON() throws {
        let json = """
            {"type":"offer","sdp":"v=0"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .offer(sdp: "v=0"))
    }

    @Test func decodesControlRequestFromFixedJSON() throws {
        let json = """
            {"type":"control","control":"seekBack"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .control(.seekBack))
    }

    @Test func decodesStopRequestFromFixedJSON() throws {
        let json = """
            {"type":"stop"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .stop)
    }

    @Test func decodesDisplayOnRequestFromFixedJSON() throws {
        let json = """
            {"type":"displayOn"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .displayOn)
    }

    @Test func decodesDisplayOffRequestFromFixedJSON() throws {
        let json = """
            {"type":"displayOff"}
            """
        let decoded = try decode(RequestPayload.self, from: json)
        #expect(decoded == .displayOff)
    }

    @Test func decodesOkResponseFromFixedJSON() throws {
        let json = """
            {"type":"ok"}
            """
        let decoded = try decode(ResponsePayload.self, from: json)
        #expect(decoded == .ok)
    }

    @Test func decodesAnswerResponseFromFixedJSON() throws {
        let json = """
            {"type":"answer","sdp":"v=0"}
            """
        let decoded = try decode(ResponsePayload.self, from: json)
        #expect(decoded == .answer(sdp: "v=0"))
    }

    @Test func decodesErrorResponseFromFixedJSON() throws {
        let json = """
            {"type":"error","message":"nope"}
            """
        let decoded = try decode(ResponsePayload.self, from: json)
        #expect(decoded == .error(message: "nope"))
    }

    @Test func decodesNotHandledResponseFromFixedJSON() throws {
        let json = """
            {"type":"notHandled"}
            """
        let decoded = try decode(ResponsePayload.self, from: json)
        #expect(decoded == .notHandled)
    }

    @Test func decodesFullReceiverRequestFromFixedJSON() throws {
        let json = """
            {"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","payload":{"type":"stop"}}
            """
        let decoded = try decode(ReceiverRequest.self, from: json)
        #expect(decoded.id == UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        #expect(decoded.payload == .stop)
    }
}

// MARK: - Helpers

private func roundTrip<T: Codable>(_ value: T, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}

private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    #expect(try roundTrip(value, as: T.self) == value)
}

private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
