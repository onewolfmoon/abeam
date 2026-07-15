import Testing
@testable import ReceiverProtocol

struct ReceiverEndpointTests {
    @Test func bonjourPersistedStringRoundTrips() {
        let endpoint = ReceiverEndpoint.bonjour(name: "Living Room")
        let persisted = endpoint.persistedString
        #expect(persisted == "bonjour:Living Room")
        #expect(ReceiverEndpoint(persistedString: persisted) == endpoint)
    }

    @Test func manualPersistedStringRoundTrips() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.42", port: 9999)
        let persisted = endpoint.persistedString
        #expect(persisted == "manual:192.168.1.42:9999")
        #expect(ReceiverEndpoint(persistedString: persisted) == endpoint)
    }

    @Test func invalidPersistedStringsFailToParse() {
        #expect(ReceiverEndpoint(persistedString: "") == nil)
        #expect(ReceiverEndpoint(persistedString: "garbage") == nil)
        #expect(ReceiverEndpoint(persistedString: "bonjour:") == nil)
        #expect(ReceiverEndpoint(persistedString: "manual:justahost") == nil)
        #expect(ReceiverEndpoint(persistedString: "manual:host:notanumber") == nil)
    }

    @Test func manualInputDefaultsPort() {
        #expect(ReceiverEndpoint(manualInput: "192.168.1.42") == .manual(host: "192.168.1.42", port: ReceiverEndpoint.defaultPort))
        #expect(ReceiverEndpoint(manualInput: "living-room.local") == .manual(host: "living-room.local", port: ReceiverEndpoint.defaultPort))
    }

    @Test func manualInputParsesExplicitPort() {
        #expect(ReceiverEndpoint(manualInput: "192.168.1.42:9191") == .manual(host: "192.168.1.42", port: 9191))
    }

    @Test func manualInputTrimsWhitespace() {
        #expect(ReceiverEndpoint(manualInput: "  192.168.1.42  ") == .manual(host: "192.168.1.42", port: ReceiverEndpoint.defaultPort))
    }

    @Test func manualInputRejectsEmptyOrInvalid() {
        #expect(ReceiverEndpoint(manualInput: "") == nil)
        #expect(ReceiverEndpoint(manualInput: "   ") == nil)
        #expect(ReceiverEndpoint(manualInput: "not a host!") == nil)
    }

    @Test func displayNameOmitsDefaultPort() {
        #expect(ReceiverEndpoint.manual(host: "192.168.1.42", port: ReceiverEndpoint.defaultPort).displayName == "192.168.1.42")
        #expect(ReceiverEndpoint.manual(host: "192.168.1.42", port: 9191).displayName == "192.168.1.42:9191")
        #expect(ReceiverEndpoint.bonjour(name: "Living Room").displayName == "Living Room")
    }
}
