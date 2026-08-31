import Network
import Testing

@testable import ReceiverProtocol

/// Tests for `ReceiverEndpoint`'s string parsing and formatting.
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
        //
        // TODO: Consider using bracketed `[fe80::1]:8787`-style notation to
        // unambiguously separate an IPv6 host from a port.
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

    @Test func manualInputTreatsBareIPv6LiteralAsWholeHost() throws {
        // A bare IPv6 literal contains more than one colon, so the parser
        // doesn't try to split off a trailing "port" segment -- doing so
        // would mis-parse "fe80::1" as host "fe80:" with port 1.
        let endpoint = try #require(ReceiverEndpoint(manualInput: "fe80::1"))
        #expect(endpoint == .manual(host: "fe80::1", port: ReceiverEndpoint.defaultPort))
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

    // MARK: - nwEndpoint

    @Test func nwEndpointForBonjour() {
        let endpoint = ReceiverEndpoint.bonjour(name: "Living Room").nwEndpoint
        #expect(
            endpoint
                == .service(
                    name: "Living Room",
                    type: ReceiverEndpoint.serviceType,
                    domain: ReceiverEndpoint.serviceDomain,
                    interface: nil
                )
        )
    }

    @Test func nwEndpointForManual() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 9000).nwEndpoint
        #expect(endpoint == .hostPort(host: "192.168.1.5", port: 9000))
    }

    @Test func nwEndpointFallsBackToDefaultPortForPortZero() {
        // Port 0 isn't usable for an actual connection, so nwEndpoint
        // treats it as invalid explicitly and falls back to defaultPort,
        // rather than passing 0 straight through (NWEndpoint.Port's own
        // rawValue initializer doesn't reject port 0 on its own).
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 0).nwEndpoint
        #expect(
            endpoint
                == .hostPort(
                    host: "192.168.1.5",
                    port: .init(rawValue: ReceiverEndpoint.defaultPort)!
                )
        )
    }
}
