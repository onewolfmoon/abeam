import Foundation
import Testing
@testable import BlittieScreen

// Covers the STUN/TURN message codec only — the part with real correctness
// risk and no dependency on networking. The networked path (a live
// NWListener actually relaying UDP between a client and a peer) isn't
// exercised here: this environment's `swift test` runs as an unsigned,
// bundle-less process, and — like the raw-hostPort NWConnection dialing
// issue hit earlier in this project — NWListener here doesn't receive
// traffic from a plain BSD-socket peer even over loopback, while a pure
// BSD-socket-to-BSD-socket loopback exchange in the same environment works
// fine. That's an environment limitation, not something to work around in
// TurnServer itself; the relay path is verified manually against the real
// signed BlittieScreen.app instead.
struct StunMessageCodecTests {
    @Test func allocateRequestRoundTripsThroughEncodeAndParse() {
        let transactionID = Data((0..<12).map { UInt8($0) })
        let original = StunMessage(
            type: StunMessageType.allocateRequest,
            transactionID: transactionID,
            attributes: [(StunAttr.lifetime, encodeUInt32(600))]
        )
        let parsed = StunMessage(parsing: original.encoded())
        #expect(parsed?.type == StunMessageType.allocateRequest)
        #expect(parsed?.transactionID == transactionID)
        #expect(parsed?.attribute(StunAttr.lifetime).flatMap(decodeUInt32) == 600)
    }

    @Test func multipleAttributesRoundTrip() {
        let transactionID = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let xorPeer = encodeXorIPv4Address(hostString: "10.0.0.5", port: 4000)!
        let payload = Data("relayed bytes".utf8)
        let original = StunMessage(
            type: StunMessageType.sendIndication,
            transactionID: transactionID,
            attributes: [(StunAttr.xorPeerAddress, xorPeer), (StunAttr.data, payload)]
        )
        let parsed = StunMessage(parsing: original.encoded())
        #expect(parsed?.attribute(StunAttr.xorPeerAddress).flatMap(decodeXorIPv4Address)?.ip == "10.0.0.5")
        #expect(parsed?.attribute(StunAttr.xorPeerAddress).flatMap(decodeXorIPv4Address)?.port == 4000)
        #expect(parsed?.attribute(StunAttr.data) == payload)
    }

    @Test func attributePaddingToFourByteBoundaryDoesNotCorruptSubsequentAttributes() {
        // "relayed bytes" is 13 bytes (not a multiple of 4), so this only
        // passes if encode/decode both apply STUN's padding rule correctly.
        let payload = Data("relayed bytes".utf8) // 13 bytes
        #expect(payload.count % 4 != 0)
        let message = StunMessage(
            type: StunMessageType.sendIndication,
            transactionID: Data(repeating: 0, count: 12),
            attributes: [(StunAttr.data, payload), (StunAttr.lifetime, encodeUInt32(600))]
        )
        let parsed = StunMessage(parsing: message.encoded())
        #expect(parsed?.attribute(StunAttr.data) == payload)
        #expect(parsed?.attribute(StunAttr.lifetime).flatMap(decodeUInt32) == 600)
    }

    @Test func rejectsDataMissingTheStunMagicCookie() {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x00; bytes[1] = 0x03 // Allocate request type, top bits clear
        // magic cookie bytes (4..<8) deliberately left as zero, not 0x2112A442
        #expect(StunMessage(parsing: Data(bytes)) == nil)
    }

    @Test func rejectsTruncatedMessages() {
        #expect(StunMessage(parsing: Data([0x00, 0x03, 0x00, 0x00])) == nil)
    }

    @Test func rejectsMessageWithLengthLongerThanAvailableData() {
        let message = StunMessage(type: StunMessageType.allocateRequest, transactionID: Data(repeating: 0, count: 12))
        var encoded = message.encoded()
        encoded[2] = 0xFF; encoded[3] = 0xFF // claim a huge attributes length
        #expect(StunMessage(parsing: encoded) == nil)
    }

    @Test func xorIPv4AddressRoundTrips() {
        let encoded = encodeXorIPv4Address(hostString: "192.168.1.42", port: 54321)
        #expect(encoded != nil)
        let decoded = encoded.flatMap(decodeXorIPv4Address)
        #expect(decoded?.ip == "192.168.1.42")
        #expect(decoded?.port == 54321)
    }

    @Test func xorAddressNeverLeaksThePlaintextPortOrOctetsInTheWire() {
        // The whole point of the XOR step: the encoded bytes must not equal
        // the plain big-endian port or the raw address octets, otherwise
        // this would just be MAPPED-ADDRESS with a different attribute type.
        let encoded = encodeXorIPv4Address(hostString: "10.0.0.1", port: 3478)
        let bytes = [UInt8](encoded!)
        #expect(bytes[2...3] != [0x0D, 0x96]) // 3478 in plain big-endian
        #expect(bytes[4...7] != [10, 0, 0, 1])
    }

    @Test func uInt32RoundTrips() {
        #expect(decodeUInt32(encodeUInt32(600)) == 600)
        #expect(decodeUInt32(encodeUInt32(0)) == 0)
    }

    @Test func messageTypesFollowStunClassEncoding() {
        // Sanity check against RFC 8656's worked values, since a mistake
        // here would make every response unrecognizable to a real client.
        #expect(StunMessageType.allocateRequest == 0x0003)
        #expect(StunMessageType.allocateSuccess == 0x0103)
        #expect(StunMessageType.refreshRequest == 0x0004)
        #expect(StunMessageType.refreshSuccess == 0x0104)
        #expect(StunMessageType.createPermissionRequest == 0x0008)
        #expect(StunMessageType.createPermissionSuccess == 0x0108)
        #expect(StunMessageType.channelBindRequest == 0x0009)
        #expect(StunMessageType.channelBindSuccess == 0x0109)
        #expect(StunMessageType.sendIndication == 0x0016)
        #expect(StunMessageType.dataIndication == 0x0017)
    }
}
