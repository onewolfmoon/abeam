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
        // split on the *last* colon so this still round-trips. (This is the
        // internal persisted representation, not user input, so it doesn't
        // need the bracket notation `init(manualInput:)` uses.)
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
        "manual:host:0",
        "unknownkind:whatever",
    ])
    func persistedStringRejectsMalformedInput(_ value: String) {
        #expect(ReceiverEndpoint(persistedString: value) == nil)
    }

    // MARK: - init?(manualInput:)

    @Test func manualInputParsesExplicitPort() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "192.168.1.5:9000"))
        #expect(endpoint == .manual(host: "192.168.1.5", port: 9000))
    }

    @Test func manualInputTrimsWhitespace() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "  192.168.1.5:9000  "))
        #expect(endpoint == .manual(host: "192.168.1.5", port: 9000))
    }

    @Test func manualInputAcceptsHostnamesWithPort() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "my-screen.local:9000"))
        #expect(endpoint == .manual(host: "my-screen.local", port: 9000))
    }

    @Test(arguments: [
        "", "   ", "my host", "my_host", "abc$def",
        // A port is required now, since Abaft's port is chosen dynamically
        // rather than being fixed.
        "192.168.1.5", "my-screen.local",
    ])
    func manualInputRejectsInvalidCharactersOrEmptyOrMissingPortInput(_ value: String) {
        #expect(ReceiverEndpoint(manualInput: value) == nil)
    }

    @Test func manualInputParsesBracketedIPv6LiteralWithPort() throws {
        let endpoint = try #require(ReceiverEndpoint(manualInput: "[fe80::1]:8787"))
        #expect(endpoint == .manual(host: "fe80::1", port: 8787))
    }

    @Test(arguments: [
        // A bare IPv6 literal has no unambiguous way to attach a port
        // without bracket notation, so it's rejected outright.
        "fe80::1",
        // Malformed bracket notation is rejected too.
        "[fe80::1]", "[fe80::1", "[fe80::1]8787", "[]:8787",
    ])
    func manualInputRejectsUnbracketedOrMalformedIPv6(_ value: String) {
        #expect(ReceiverEndpoint(manualInput: value) == nil)
    }

    @Test func manualInputRejectsPortZero() {
        #expect(ReceiverEndpoint(manualInput: "host:0") == nil)
    }

    @Test func manualInputRejectsUnparseablePort() {
        // Unlike before a port was required, a trailing segment after the
        // last colon that isn't a valid UInt16 no longer falls back to
        // treating the whole string as the host -- it's rejected outright.
        #expect(ReceiverEndpoint(manualInput: "host:99999999") == nil)
    }

    // MARK: - displayName

    @Test func displayNameForBonjourIsJustTheName() {
        #expect(ReceiverEndpoint.bonjour(name: "Living Room").displayName == "Living Room")
    }

    @Test func displayNameAlwaysIncludesPort() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 8787)
        #expect(endpoint.displayName == "192.168.1.5:8787")
    }

    @Test func displayNameIncludesNonDefaultPort() {
        let endpoint = ReceiverEndpoint.manual(host: "192.168.1.5", port: 9000)
        #expect(endpoint.displayName == "192.168.1.5:9000")
    }

    @Test func displayNameBracketsIPv6Host() {
        let endpoint = ReceiverEndpoint.manual(host: "fe80::1", port: 8787)
        #expect(endpoint.displayName == "[fe80::1]:8787")
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
