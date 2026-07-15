import Foundation
import Testing
@testable import ReceiverProtocol

struct WireProtocolTests {
    private func roundTrip(_ request: ReceiverRequest) throws -> ReceiverRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ReceiverRequest.self, from: data)
    }

    private func roundTrip(_ response: ReceiverResponse) throws -> ReceiverResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(ReceiverResponse.self, from: data)
    }

    @Test func youtubeRequestRoundTrips() throws {
        let request = ReceiverRequest(payload: .youtube(url: "https://example.com/video.mp4"))
        #expect(try roundTrip(request) == request)
    }

    @Test func offerRequestRoundTrips() throws {
        let request = ReceiverRequest(payload: .offer(sdp: "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"))
        #expect(try roundTrip(request) == request)
    }

    @Test func controlRequestRoundTrips() throws {
        for control: ReceiverControl in [.playPause, .seekBack, .seekForward] {
            let request = ReceiverRequest(payload: .control(control))
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func stopRequestRoundTrips() throws {
        let request = ReceiverRequest(payload: .stop)
        #expect(try roundTrip(request) == request)
    }

    @Test func responsesRoundTrip() throws {
        let id = UUID()
        let cases: [ResponsePayload] = [.ok, .answer(sdp: "v=0"), .error(message: "bad"), .notHandled]
        for payload in cases {
            let response = ReceiverResponse(id: id, payload: payload)
            #expect(try roundTrip(response) == response)
        }
    }

    // The whole point of the envelope's `id` field: two requests in flight on
    // the same persistent connection must not be confused for one another.
    @Test func distinctRequestsGetDistinctIDs() {
        let a = ReceiverRequest(payload: .stop)
        let b = ReceiverRequest(payload: .stop)
        #expect(a.id != b.id)
    }
}
