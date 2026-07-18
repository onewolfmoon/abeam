import Darwin
import Foundation
import Network
import ReceiverProtocol

// Minimal, unauthenticated TURN relay (RFC 8656) so a Chrome-based Sender's
// WebRTC offer can include at least one ICE candidate the WebKit-based
// Receiver can actually dial: Chrome mDNS-obfuscates its own *host*
// candidates (`<uuid>.local`, unresolvable by WebKit), but a TURN Allocate
// response always carries a literal IP for both the relayed and the
// server-reflexive candidate it yields — Chrome never obfuscates those. A
// plain STUN server would get the reflexive candidate for free too (the
// Allocate response's XOR-MAPPED-ADDRESS *is* that), so there's no separate
// STUN mode here — just the TURN subset a WebRTC client actually speaks:
// Allocate, Refresh, CreatePermission, ChannelBind, Send indications, and
// ChannelData relaying. No MESSAGE-INTEGRITY/REALM/NONCE challenge, no TCP
// allocations, no IPv6 — this is LAN-only with the same no-auth trust model
// as ReceiverSocketServer, and only ever needs to serve the two WKWebViews
// this app itself drives plus whatever Sender is on the LAN.
actor TurnServer {
    private let controlQueue = DispatchQueue(label: "TurnServer.control")
    private var controlListener: NWListener?
    private var allocations: [ObjectIdentifier: Allocation] = [:]
    private var reaperTask: Task<Void, Never>?

    private init() {}

    @discardableResult
    static func start() -> TurnServer {
        let server = TurnServer()
        Task { await server.start() }
        return server
    }

    private func start() {
        guard let port = NWEndpoint.Port(rawValue: ReceiverEndpoint.defaultTurnPort),
              let listener = try? NWListener(using: .udp, on: port) else {
            FileHandle.standardError.write(Data("TURN server failed to bind port \(ReceiverEndpoint.defaultTurnPort)\n".utf8))
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.acceptClient(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("TURN server failed: \(error)\n".utf8))
            }
        }
        listener.start(queue: controlQueue)
        controlListener = listener
        startReaper()
    }

    // MARK: - Per-client control flow
    //
    // NWListener demultiplexes inbound UDP by source (address, port) into a
    // distinct NWConnection per client, same as ReceiverSocketServer relies
    // on for TCP — every STUN control message *and* every ChannelData frame
    // for a given client arrives on this one connection, since TURN only
    // ever allocates a second (relay) socket for server<->peer traffic, not
    // for client<->server traffic.

    private func acceptClient(_ connection: NWConnection) {
        let allocation = Allocation(controlConnection: connection)
        allocations[ObjectIdentifier(connection)] = allocation
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { await self?.releaseAllocation(for: connection) }
            default:
                break
            }
        }
        connection.start(queue: controlQueue)
        receiveLoop(on: connection)
    }

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            if let content, !content.isEmpty {
                Task { await self?.handleDatagram(content, from: connection) }
                self?.receiveLoop(on: connection)
            } else if error == nil {
                self?.receiveLoop(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleDatagram(_ data: Data, from connection: NWConnection) async {
        guard let allocation = allocations[ObjectIdentifier(connection)] else { return }
        let leadingByte = data.first ?? 0
        // STUN message types always have their top two bits clear; valid
        // TURN channel numbers (0x4000-0x7FFF) always have them as 01 — the
        // standard way to tell a control message from a ChannelData frame
        // sharing the same 5-tuple.
        if leadingByte & 0xC0 == 0x00 {
            guard let message = StunMessage(parsing: data) else { return }
            await handleStunMessage(message, allocation: allocation, connection: connection)
        } else if leadingByte & 0xC0 == 0x40 {
            handleChannelData(data, allocation: allocation)
        }
    }

    private func handleStunMessage(_ message: StunMessage, allocation: Allocation, connection: NWConnection) async {
        switch message.type {
        case StunMessageType.allocateRequest:
            handleAllocate(message, allocation: allocation, connection: connection)
        case StunMessageType.refreshRequest:
            handleRefresh(message, allocation: allocation, connection: connection)
        case StunMessageType.createPermissionRequest:
            handleCreatePermission(message, allocation: allocation, connection: connection)
        case StunMessageType.channelBindRequest:
            handleChannelBind(message, allocation: allocation, connection: connection)
        case StunMessageType.sendIndication:
            handleSendIndication(message, allocation: allocation)
        default:
            break
        }
    }

    private func handleAllocate(_ message: StunMessage, allocation: Allocation, connection: NWConnection) {
        if allocation.relaySocket == nil {
            guard let relay = RelaySocket(onReceive: { [weak self] data, peerIP, peerPort in
                Task { await self?.relayDataReceived(data, fromPeerIP: peerIP, peerPort: peerPort, connection: connection) }
            }) else {
                FileHandle.standardError.write(Data("TURN allocate: couldn't open relay socket\n".utf8))
                return
            }
            allocation.relaySocket = relay
        }
        allocation.expiresAt = Date().addingTimeInterval(Allocation.lifetimeSeconds)

        guard case .hostPort(let clientHost, let clientPort) = connection.endpoint,
              case .hostPort(let localHost, _) = connection.currentPath?.localEndpoint,
              let relayPort = allocation.relaySocket?.localPort else {
            return
        }

        var attributes: [(type: UInt16, value: Data)] = []
        if let xorMapped = encodeXorIPv4Address(hostString: "\(clientHost)", port: clientPort.rawValue) {
            attributes.append((StunAttr.xorMappedAddress, xorMapped))
        }
        if let xorRelayed = encodeXorIPv4Address(hostString: "\(localHost)", port: relayPort) {
            attributes.append((StunAttr.xorRelayedAddress, xorRelayed))
        }
        attributes.append((StunAttr.lifetime, encodeUInt32(UInt32(Allocation.lifetimeSeconds))))

        let response = StunMessage(type: StunMessageType.allocateSuccess, transactionID: message.transactionID, attributes: attributes)
        send(response, on: connection)
    }

    private func handleRefresh(_ message: StunMessage, allocation: Allocation, connection: NWConnection) {
        let requestedLifetime = message.attribute(StunAttr.lifetime).flatMap(decodeUInt32)
        if requestedLifetime == 0 {
            releaseAllocation(for: connection)
        } else {
            allocation.expiresAt = Date().addingTimeInterval(Allocation.lifetimeSeconds)
        }
        let response = StunMessage(
            type: StunMessageType.refreshSuccess,
            transactionID: message.transactionID,
            attributes: [(StunAttr.lifetime, encodeUInt32(UInt32(Allocation.lifetimeSeconds)))]
        )
        send(response, on: connection)
    }

    private func handleCreatePermission(_ message: StunMessage, allocation: Allocation, connection: NWConnection) {
        for (type, value) in message.attributes where type == StunAttr.xorPeerAddress {
            if let (ip, _) = decodeXorIPv4Address(value) {
                allocation.permittedPeerIPs.insert(ip)
            }
        }
        let response = StunMessage(type: StunMessageType.createPermissionSuccess, transactionID: message.transactionID)
        send(response, on: connection)
    }

    private func handleChannelBind(_ message: StunMessage, allocation: Allocation, connection: NWConnection) {
        guard let channelData = message.attribute(StunAttr.channelNumber),
              channelData.count >= 2 else { return }
        let channelNumber = UInt16(channelData[channelData.startIndex]) << 8 | UInt16(channelData[channelData.startIndex + 1])
        guard (0x4000...0x7FFF).contains(channelNumber),
              let peerAddress = message.attribute(StunAttr.xorPeerAddress),
              let (ip, port) = decodeXorIPv4Address(peerAddress) else { return }

        // ChannelBind implicitly installs/refreshes a permission for the
        // bound peer too (RFC 8656 §11.7) — a client that only ever binds a
        // channel (never calls CreatePermission directly, which is the
        // common case for WebRTC's TURN client) still gets relayed traffic.
        allocation.permittedPeerIPs.insert(ip)
        allocation.channelToPeer[channelNumber] = (ip, port)
        allocation.peerToChannel["\(ip):\(port)"] = channelNumber

        let response = StunMessage(type: StunMessageType.channelBindSuccess, transactionID: message.transactionID)
        send(response, on: connection)
    }

    private func handleSendIndication(_ message: StunMessage, allocation: Allocation) {
        guard let peerAddress = message.attribute(StunAttr.xorPeerAddress),
              let (ip, port) = decodeXorIPv4Address(peerAddress),
              allocation.permittedPeerIPs.contains(ip),
              let payload = message.attribute(StunAttr.data),
              let relay = allocation.relaySocket else { return }
        relay.send(payload, toIP: ip, port: port)
    }

    private func handleChannelData(_ data: Data, allocation: Allocation) {
        guard data.count >= 4 else { return }
        let channelNumber = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        let length = Int(UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3]))
        guard let (ip, port) = allocation.channelToPeer[channelNumber],
              allocation.permittedPeerIPs.contains(ip),
              data.count >= 4 + length,
              let relay = allocation.relaySocket else { return }
        let payload = data.subdata(in: (data.startIndex + 4)..<(data.startIndex + 4 + length))
        relay.send(payload, toIP: ip, port: port)
    }

    // MARK: - Peer -> client direction

    private func relayDataReceived(_ data: Data, fromPeerIP peerIP: String, peerPort: UInt16, connection: NWConnection) async {
        guard let allocation = allocations[ObjectIdentifier(connection)],
              allocation.permittedPeerIPs.contains(peerIP) else { return }

        if let channelNumber = allocation.peerToChannel["\(peerIP):\(peerPort)"] {
            var framed = Data()
            framed.append(UInt8(channelNumber >> 8)); framed.append(UInt8(channelNumber & 0xFF))
            framed.append(UInt8(data.count >> 8)); framed.append(UInt8(data.count & 0xFF))
            framed.append(data)
            sendRaw(framed, on: connection)
        } else if let xorPeer = encodeXorIPv4Address(hostString: peerIP, port: peerPort) {
            let indication = StunMessage(
                type: StunMessageType.dataIndication,
                transactionID: Data((0..<12).map { _ in UInt8.random(in: 0...255) }),
                attributes: [(StunAttr.xorPeerAddress, xorPeer), (StunAttr.data, data)]
            )
            send(indication, on: connection)
        }
    }

    // MARK: - Wire helpers

    private func send(_ message: StunMessage, on connection: NWConnection) {
        sendRaw(message.encoded(), on: connection)
    }

    private nonisolated func sendRaw(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Lifecycle

    private func releaseAllocation(for connection: NWConnection) {
        allocations.removeValue(forKey: ObjectIdentifier(connection))?.relaySocket?.close()
    }

    private func startReaper() {
        reaperTask?.cancel()
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.evictExpiredAllocations()
            }
        }
    }

    private func evictExpiredAllocations() {
        let now = Date()
        for (key, allocation) in allocations where allocation.expiresAt < now {
            allocation.relaySocket?.close()
            allocations.removeValue(forKey: key)
        }
    }
}

// MARK: - Allocation state

private final class Allocation {
    static let lifetimeSeconds: TimeInterval = 600

    let controlConnection: NWConnection
    var relaySocket: RelaySocket?
    var permittedPeerIPs: Set<String> = []
    var channelToPeer: [UInt16: (ip: String, port: UInt16)] = [:]
    var peerToChannel: [String: UInt16] = [:]
    var expiresAt: Date = Date().addingTimeInterval(Allocation.lifetimeSeconds)

    init(controlConnection: NWConnection) {
        self.controlConnection = controlConnection
    }
}

// MARK: - Relay socket
//
// TURN's relay side is inherently "one socket, many peers" (arbitrary
// sendto/recvfrom targets discovered at runtime via CreatePermission), which
// doesn't fit Network.framework's per-flow NWConnection model — that's built
// for a fixed pair of endpoints per object, whereas a relay allocation needs
// to talk to whichever peer addresses get permitted after the fact. A raw
// BSD datagram socket is the standard shape for this half of a TURN server;
// everything else in this file (and the rest of the app) stays on
// Network.framework, where its per-flow model fits naturally.
private final class RelaySocket {
    private let fd: Int32
    let localPort: UInt16
    private let readSource: DispatchSourceRead

    init?(onReceive: @escaping @Sendable (Data, String, UInt16) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(fd); return nil }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        guard nameResult == 0 else { Darwin.close(fd); return nil }

        self.fd = fd
        self.localPort = UInt16(bigEndian: bound.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "TurnServer.relay"))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &fromAddr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard count > 0 else { return }
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ipString = withUnsafePointer(to: &fromAddr.sin_addr) { addrPtr -> String? in
                guard inet_ntop(AF_INET, addrPtr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return ipBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            guard let ipString else { return }
            let port = UInt16(bigEndian: fromAddr.sin_port)
            onReceive(Data(buffer[0..<count]), ipString, port)
        }
        readSource = source
        source.resume()
    }

    func send(_ data: Data, toIP ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return }
        _ = data.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, rawBuffer.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        readSource.cancel()
        Darwin.close(fd)
    }
}

// MARK: - STUN message codec
//
// Kept free of any networking so it's unit-testable in isolation. Covers
// only what TURN needs (see file header) — no MESSAGE-INTEGRITY/FINGERPRINT
// generation or verification, since this server never challenges or signs
// anything.

struct StunMessageType {
    static let allocateRequest: UInt16 = 0x0003
    static let allocateSuccess: UInt16 = 0x0103
    static let refreshRequest: UInt16 = 0x0004
    static let refreshSuccess: UInt16 = 0x0104
    static let createPermissionRequest: UInt16 = 0x0008
    static let createPermissionSuccess: UInt16 = 0x0108
    static let channelBindRequest: UInt16 = 0x0009
    static let channelBindSuccess: UInt16 = 0x0109
    static let sendIndication: UInt16 = 0x0016
    static let dataIndication: UInt16 = 0x0017
}

struct StunAttr {
    static let xorMappedAddress: UInt16 = 0x0020
    static let channelNumber: UInt16 = 0x000C
    static let lifetime: UInt16 = 0x000D
    static let xorPeerAddress: UInt16 = 0x0012
    static let data: UInt16 = 0x0013
    static let xorRelayedAddress: UInt16 = 0x0016
}

struct StunMessage {
    static let magicCookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    var type: UInt16
    var transactionID: Data
    var attributes: [(type: UInt16, value: Data)]

    init(type: UInt16, transactionID: Data, attributes: [(type: UInt16, value: Data)] = []) {
        self.type = type
        self.transactionID = transactionID
        self.attributes = attributes
    }

    init?(parsing data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 20 else { return nil }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard type & 0xC000 == 0 else { return nil }
        let length = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard Array(bytes[4..<8]) == Self.magicCookieBytes, bytes.count >= 20 + length else { return nil }

        var attrs: [(UInt16, Data)] = []
        var offset = 20
        let end = 20 + length
        while offset + 4 <= end {
            let attrType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let attrLength = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            offset += 4
            guard offset + attrLength <= end else { return nil }
            attrs.append((attrType, Data(bytes[offset..<(offset + attrLength)])))
            offset += attrLength + (4 - attrLength % 4) % 4
        }

        self.type = type
        self.transactionID = Data(bytes[8..<20])
        self.attributes = attrs
    }

    func attribute(_ type: UInt16) -> Data? {
        attributes.first { $0.type == type }?.value
    }

    func encoded() -> Data {
        var body = Data()
        for (type, value) in attributes {
            body.append(UInt8(type >> 8)); body.append(UInt8(type & 0xFF))
            body.append(UInt8(value.count >> 8)); body.append(UInt8(value.count & 0xFF))
            body.append(value)
            body.append(Data(repeating: 0, count: (4 - value.count % 4) % 4))
        }
        var message = Data()
        message.append(UInt8(type >> 8)); message.append(UInt8(type & 0xFF))
        message.append(UInt8(body.count >> 8)); message.append(UInt8(body.count & 0xFF))
        message.append(contentsOf: Self.magicCookieBytes)
        message.append(transactionID)
        message.append(body)
        return message
    }
}

func encodeUInt32(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

func decodeUInt32(_ data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data)
    return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

// XOR-ed per RFC 5389 §15.2: the port is XORed with the top 16 bits of the
// magic cookie, the address with the full 32-bit cookie. IPv4 only, matching
// the rest of this app's LAN assumptions.
func encodeXorIPv4Address(hostString: String, port: UInt16) -> Data? {
    var addr = in_addr()
    guard hostString.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
    let ipBytes = withUnsafeBytes(of: addr.s_addr) { Array($0) }
    let cookie = StunMessage.magicCookieBytes
    let xPort = port ^ 0x2112
    var value = Data([0, 0x01, UInt8(xPort >> 8), UInt8(xPort & 0xFF)])
    for i in 0..<4 { value.append(ipBytes[i] ^ cookie[i]) }
    return value
}

// Used when the Sender's own signaling connection resolved over IPv6 (see
// ReceiverSocketServer's .iceConfig handling) and a real IPv4 literal is
// needed instead, since this relay is IPv4-only. Prefers en0 (a Mac's
// typical primary Wi-Fi/Ethernet interface) but accepts any non-loopback
// candidate rather than requiring an exact match.
func primaryIPv4Address() -> String? {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
    defer { freeifaddrs(ifaddrPtr) }

    var fallback: String?
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              interface.ifa_flags & UInt32(IFF_UP) != 0,
              interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ip: String? = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
            var sinAddr = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        guard let ip else { continue }

        if String(cString: interface.ifa_name) == "en0" { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}

func decodeXorIPv4Address(_ value: Data) -> (ip: String, port: UInt16)? {
    let bytes = [UInt8](value)
    guard bytes.count >= 8, bytes[1] == 0x01 else { return nil }
    let cookie = StunMessage.magicCookieBytes
    let xPort = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    let port = xPort ^ 0x2112
    var ipBytes = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 { ipBytes[i] = bytes[4 + i] ^ cookie[i] }
    let ip = ipBytes.map(String.init).joined(separator: ".")
    return (ip, port)
}
