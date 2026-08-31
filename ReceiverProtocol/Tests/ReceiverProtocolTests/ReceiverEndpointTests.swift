import Testing

@testable import ReceiverProtocol

/// Tests for `ReceiverEndpoint`'s string parsing and formatting. This is the
/// logic that turns a user-typed address (or a value persisted to disk) into
/// something Abeam can connect to, so it's worth pinning down exactly what
/// counts as valid input and what the fallback behavior is for the rest.
struct ReceiverEndpointTests {

    // MARK: - persistedString round trips

    @Test func bonjourPersistedStringRoundTrips() throws {
        let endpoint = ReceiverEndpoint.bonjour(name: "Living Room")
        let restored = try #require(ReceiverEndpoint(persistedString: endpoint.persistedString))
        #expect(restored == endpoint)
    }

    @Test func manualPersistedStringRoundTrips() throws {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 9000)
        let restored = try #require(ReceiverEndpoint(persistedString: endpoint.persistedString))
        #expect(restored == endpoint)
    }

    @Test func manualPersistedStringRoundTripsWithColonInHost() throws {
        // IPv6 literals contain colons, which is also the separator this
        // format uses between host and port -- the parser is expected to
        // split on the *last* colon so this still round-trips.
        let endpoint = ReceiverEndpoint.manual(host: "fe80::1", port: 8787)
        let restored = try #require(ReceiverEndpoint(persistedString: endpoint.persistedString))
        #expect(restored == endpoint)
    }

    // MARK: - init?(persistedString:) rejects malformed input

    @Test(arguments: [
        "",
        "bonjour:",
        "manual:",
        "manual:hostwithoutport",
        "manual:host:notanumber",
        "manual::8787",
        "unknownkind:whatever",
    ])
    func persistedStringRejectsMalformedInput(_ value: String) {
        #expect(ReceiverEndpoint(persistedString: value) == nil)
    }

    // MARK: - init?(manualInput:)

    @Test func manualInputTrimsWhitespaceAndUsesDefaultPort() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "  192.168.1.5  "))
        #expect(endpoint == .manual(host: "192.168.1.5", port: ReceiverEndpoint.defaultPort))
    }

    @Test func manualInputParsesExplicitPort() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "192.168.1.5:9000"))
        #expect(endpoint == .manual(host: "192.168.1.5", port: 9000))
    }

    @Test func manualInputAcceptsHostnames() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "my-screen.local"))
        #expect(endpoint == .manual(host: "my-screen.local", port: ReceiverEndpoint.defaultPort))
    }

    @Test(arguments: ["", "   ", "my host", "my_host", "abc$def"])
    func manualInputRejectsInvalidCharactersOrEmptyInput(_ value: String) {
        #expect(ReceiverEndpoint(manualInput: value) == nil)
    }

    @Test func manualInputFallsBackToWholeStringAsHostWhenPortIsUnparseable() throws {
        // Current, deliberately-pinned-down behavior: a trailing segment
        // after the last colon that isn't a valid UInt16 doesn't reject the
        // input -- it falls back to treating the entire trimmed string
        // (colon included) as the host, with the default port.
        let endpoint = try #require(ReceiverEndpoint(manualInput: "host:99999999"))
        #expect(endpoint == .manual(host: "host:99999999", port: ReceiverEndpoint.defaultPort))
    }

    // MARK: - displayName

    @Test func displayNameForBonjourIsJustTheName() {
        #expect(ReceiverEndpoint.bonjour(name: "Living Room").displayName == "Living Room")
    }

    @Test func displayNameOmitsDefaultPort() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: ReceiverEndpoint.defaultPort)
        #expect(endpoint.displayName == "192.168.1.5")
    }

    @Test func displayNameIncludesNonDefaultPort() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 9000)
        #expect(endpoint.displayName == "192.168.1.5:9000")
    }
}
