import Foundation
import Network

/// Identification of an Abaft screen. Screens can be selected by Bonjour
/// autodiscovery or as a manually entered address.
public enum ReceiverEndpoint: Equatable, Sendable {
    case bonjour(name: String)
    case manual(host: String, port: UInt16)

    public static let serviceType = "_blittie-screen._tcp"
    public static let serviceDomain = "local."
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
            return .hostPort(
                host: .init(host),
                port: .init(rawValue: port) ?? .init(
                    rawValue: Self.defaultPort
                )!
            )
        }
    }

    public var displayName: String {
        switch self {
        case .bonjour(let name):
            return name
        case .manual(let host, let port):
            return port == Self.defaultPort ? host : "\(host):\(port)"
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
            guard let lastColon = rest.lastIndex(of: ":"),
                let port = UInt16(rest[rest.index(after: lastColon)...])
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
    /// be an IP address or a hostname, optionally with a port. If the port is
    /// omitted, `defaultPort` is used.
    public init?(manualInput input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.range(
                of: #"^[a-zA-Z0-9.\-:]+$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        if let lastColon = trimmed.lastIndex(of: ":"),
            let port = UInt16(trimmed[trimmed.index(after: lastColon)...])
        {
            self = .manual(
                host: String(trimmed[trimmed.startIndex..<lastColon]),
                port: port
            )
        } else {
            self = .manual(host: trimmed, port: Self.defaultPort)
        }
    }
}
