import Foundation

/// A local network interface's name and IPv4 address, e.g. ("en0", "192.168.1.5").
struct LocalNetworkAddress: Identifiable {
    var id: String { "\(interface):\(address)" }
    let interface: String
    let address: String

    /// The active, non-loopback IPv4 addresses of this machine, one per
    /// interface, in interface enumeration order.
    static func currentAddresses() -> [LocalNetworkAddress] {
        var addresses: [LocalNetworkAddress] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = ptr.pointee.ifa_flags
            guard
                flags & UInt32(IFF_UP) == UInt32(IFF_UP),
                flags & UInt32(IFF_LOOPBACK) == 0,
                let addr = ptr.pointee.ifa_addr,
                addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            addresses.append(
                LocalNetworkAddress(
                    interface: String(cString: ptr.pointee.ifa_name),
                    address: String(cString: hostBuffer)
                )
            )
        }
        return addresses
    }
}
