import Foundation
import Network

/// Identification of an Abaft screen. Screens can be selected by Bonjour
/// autodiscovery or as a manually entered address.
///
/// This is the logic that turns a user-typed address (or a value persisted
/// to disk) into something Abeam can connect to.
public enum ReceiverEndpoint: Equatable, Sendable {
    case bonjour(name: String)
    case manual(host: String, port: UInt16)

    public static let serviceType = "_blittie-screen._tcp"
    public static let serviceDomain = "local."

    /// Abaft listens on a port chosen dynamically by the OS, so this isn't
    /// the port any actual receiver uses. It exists only as a last-resort
    /// fallback for constructing a `.manual` endpoint whose port is
    /// otherwise unusable (see `nwEndpoint` below).
    public static let defaultPort: UInt16 = 8787

    public var nwEndpoint: NWEndpoint {
        switch self {
        case .bonjour(let name):
            return .service(
                name: name,
                type: Self.serviceType,
                domain: Self.serviceDomain,
                interface: nil
            )
        case .manual(let host, let port):
            // The public initializers already reject port 0, but a
            // .manual value can also be constructed directly (bypassing
            // them), and NWEndpoint.Port's own rawValue initializer
            // doesn't reject port 0 on its own -- so this is a last line
            // of defense, falling back to defaultPort instead.
            let validPort: NWEndpoint.Port? = port == 0 ? nil : .init(rawValue: port)
            return .hostPort(
                host: .init(host),
                port: validPort ?? .init(rawValue: Self.defaultPort)!
            )
        }
    }

    public var displayName: String {
        switch self {
        case .bonjour(let name):
            return name
        case .manual(let host, let port):
            // Abaft's port varies per instance, so it's always shown. An
            // IPv6 literal is bracketed so the result stays unambiguous and
            // round-trips through `init(manualInput:)`.
            let bracketedHost = host.contains(":") ? "[\(host)]" : host
            return "\(bracketedHost):\(port)"
        }
    }

    public var persistedString: String {
        switch self {
        case .bonjour(let name): return "bonjour:\(name)"
        case .manual(let host, let port): return "manual:\(host):\(port)"
        }
    }

    public init?(persistedString value: String) {
        if value.hasPrefix("bonjour:") {
            let name = String(value.dropFirst("bonjour:".count))
            guard !name.isEmpty else { return nil }
            self = .bonjour(name: name)
        } else if value.hasPrefix("manual:") {
            let rest = value.dropFirst("manual:".count)
            // Port 0 isn't usable for an actual connection, so reject it
            // outright rather than persisting a value that could never
            // successfully connect.
            guard let lastColon = rest.lastIndex(of: ":"),
                let port = UInt16(rest[rest.index(after: lastColon)...]),
                port != 0
            else {
                return nil
            }
            let host = String(rest[rest.startIndex..<lastColon])
            guard !host.isEmpty else { return nil }
            self = .manual(host: host, port: port)
        } else {
            return nil
        }
    }

    /// Creates a ReceiverEndpoint from an address.
    /// - Parameter input: An address in the form of a URL authority. This can
    /// be an IP address or a hostname, and must include a port, since Abaft's
    /// receiver port is chosen dynamically rather than being fixed. An IPv6
    /// literal must be bracketed to carry a port unambiguously (e.g.
    /// `[fe80::1]:8787`).
    public init?(manualInput input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard
                let closeBracket = trimmed.firstIndex(of: "]"),
                trimmed.index(after: closeBracket) < trimmed.endIndex,
                trimmed[trimmed.index(after: closeBracket)] == ":"
            else { return nil }
            let host = String(
                trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket]
            )
            let portString = trimmed[trimmed.index(closeBracket, offsetBy: 2)...]
            guard
                !host.isEmpty,
                host.range(of: #"^[a-fA-F0-9:]+$"#, options: .regularExpression)
                    != nil,
                let port = UInt16(portString),
                port != 0
            else { return nil }
            self = .manual(host: host, port: port)
            return
        }

        guard
            trimmed.range(
                of: #"^[a-zA-Z0-9.\-:]+$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        // More than one colon (outside of bracket notation, handled above)
        // means this is a bare IPv6 literal with no unambiguous way to
        // attach a port, so it's rejected rather than guessed at.
        guard
            trimmed.filter({ $0 == ":" }).count == 1,
            let lastColon = trimmed.lastIndex(of: ":"),
            let port = UInt16(trimmed[trimmed.index(after: lastColon)...]),
            // Port 0 isn't usable for an actual connection -- reject the
            // input outright rather than silently falling back to some
            // other port the user didn't ask for.
            port != 0
        else {
            return nil
        }
        let host = String(trimmed[trimmed.startIndex..<lastColon])
        guard !host.isEmpty else { return nil }
        self = .manual(host: host, port: port)
    }
}
