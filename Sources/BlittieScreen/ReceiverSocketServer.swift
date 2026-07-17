import Foundation
import Network
import ReceiverProtocol
import Security

// LAN-only control surface (no auth, no STUN/TURN) — same trust model as the
// HTTP server this replaces. One NWListener carries both the WebSocket
// transport and the Bonjour advertisement (`.service` is just a settable
// property on the listener, not a separate registration object).
//
// A second, TLS-wrapped listener on defaultWSSPort serves the same protocol
// over wss:// for browser-based Senders, which can't open a plain ws://
// connection from an https-hosted page (mixed content) and need a secure
// context for getDisplayMedia regardless. It uses a self-signed identity the
// operator generates once (see loadTLSIdentity below) rather than a
// CA-issued cert, since this never needs to leave the LAN/tailnet — each
// browser/device just needs to visit https://<address>:<wssPort> once and
// accept the certificate warning before a WebSocket connection to it will
// succeed. Both listeners feed the same accept/handle path below, so
// "latest Sender wins" preemption and request handling don't care which
// transport a given connection came in on.
//
// "Latest Sender wins": activeSessionConnection tracks whichever connection
// most recently started a session (video/offer). A *different* connection
// doing the same preempts it — cancels the old connection (so that Sender's
// socket drops and it can reconnect/show disconnected) before handing off to
// SessionCoordinator, which already tears down the old session on its own.
// control/stop apply regardless of which connection sends them, matching the
// old HTTP routes' behavior.
actor ReceiverSocketServer {
    private let coordinator: SessionCoordinator
    private var listener: NWListener?
    private var tlsListener: NWListener?
    private var activeSessionConnection: NWConnection?
    private let queue = DispatchQueue(label: "ReceiverSocketServer.nw")

    private init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    @discardableResult
    static func start(coordinator: SessionCoordinator) -> ReceiverSocketServer {
        let server = ReceiverSocketServer(coordinator: coordinator)
        Task { await server.start() }
        return server
    }

    private func start() {
        startPlainListener()
        startTLSListener()
    }

    private func startPlainListener() {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        guard let port = NWEndpoint.Port(rawValue: ReceiverEndpoint.defaultPort),
              let listener = try? NWListener(using: params, on: port) else {
            FileHandle.standardError.write(Data("Receiver socket server failed to bind port \(ReceiverEndpoint.defaultPort)\n".utf8))
            return
        }
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Receiver",
            type: ReceiverEndpoint.serviceType,
            domain: ReceiverEndpoint.serviceDomain
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("Receiver socket server (ws) failed: \(error)\n".utf8))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func startTLSListener() {
        guard let identity = Self.loadTLSIdentity() else {
            let message = "No TLS identity at \(Self.tlsIdentityURL.path); wss:// listener not started. "
                + "See setup docs to generate a self-signed identity.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let port = NWEndpoint.Port(rawValue: ReceiverEndpoint.defaultWSSPort),
              let listener = try? NWListener(using: params, on: port) else {
            FileHandle.standardError.write(Data("Receiver socket server failed to bind port \(ReceiverEndpoint.defaultWSSPort)\n".utf8))
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("Receiver socket server (wss) failed: \(error)\n".utf8))
            }
        }
        listener.start(queue: queue)
        self.tlsListener = listener
    }

    // Loaded from a PKCS#12 file the operator generates once with openssl
    // (see setup docs) rather than generated at runtime — Security.framework
    // has no convenient "create a self-signed identity" API, and a fixed
    // identity across launches means a browser's one-time certificate-trust
    // decision keeps holding instead of re-prompting every relaunch.
    private static let tlsIdentityURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Blittie Screen/tls-identity.p12")
    private static let tlsIdentityPassphrase = "blittie"

    private static func loadTLSIdentity() -> sec_identity_t? {
        guard let data = try? Data(contentsOf: tlsIdentityURL) else { return nil }

        let options: [String: Any] = [kSecImportExportPassphrase as String: tlsIdentityPassphrase]
        var rawItems: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let identity = items.first?[kSecImportItemIdentity as String] else {
            return nil
        }
        // SecPKCS12Import's documented result shape guarantees this key, when
        // present, is a SecIdentity — the guard above already confirmed presence.
        return sec_identity_create((identity as! SecIdentity))
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { await self?.connectionDidClose(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    private func connectionDidClose(_ connection: NWConnection) {
        if activeSessionConnection === connection {
            activeSessionConnection = nil
        }
    }

    // nonisolated so the recursive re-receive can be scheduled directly from
    // NWConnection's own callback queue without an actor hop; only the
    // decoded message handling below touches actor state.
    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            if let content, !content.isEmpty {
                Task { await self?.handle(content, from: connection) }
                self?.receiveLoop(on: connection)
            } else {
                // An empty read with no error is how NWConnection reports a
                // clean remote close (EOF) — it doesn't reliably drive this
                // connection's own stateUpdateHandler on its own. Cancelling
                // it ourselves routes through accept(_:)'s existing
                // .cancelled handling (which clears activeSessionConnection)
                // instead of duplicating that logic here.
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) async {
        guard let request = try? JSONDecoder().decode(ReceiverRequest.self, from: data) else { return }
        let responsePayload = await process(request.payload, from: connection)
        send(ReceiverResponse(id: request.id, payload: responsePayload), on: connection)
    }

    private func process(_ payload: RequestPayload, from connection: NWConnection) async -> ResponsePayload {
        switch payload {
        case .video(let sharePayload):
            // Validation (does this look like a link one of our parsers
            // recognizes?) now lives in SessionCoordinator/VideoParserRegistry,
            // since it needs to actually try each parser to know. Only
            // preempt the current session/connection on success, matching
            // the old bare-URL-validation behavior.
            guard await coordinator.startVideo(payload: sharePayload, onEnd: .closeWindow) else {
                return .error(message: "no video parser recognized this link")
            }
            preempt(newOwner: connection)
            return .ok

        case .offer(let sdp):
            preempt(newOwner: connection)
            do {
                let answer = try await coordinator.startOffer(sdp, onEnd: .closeWindow)
                return .answer(sdp: answer)
            } catch {
                return .error(message: "\(error)")
            }

        case .control(let control):
            let handled = await coordinator.sendControl(control.sessionCoordinatorControl)
            return handled ? .ok : .notHandled

        case .stop:
            let handled = await coordinator.stop()
            return handled ? .ok : .notHandled
        }
    }

    private func preempt(newOwner connection: NWConnection) {
        if let activeSessionConnection, activeSessionConnection !== connection {
            activeSessionConnection.cancel()
        }
        activeSessionConnection = connection
    }

    private nonisolated func send(_ response: ReceiverResponse, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

private extension ReceiverControl {
    var sessionCoordinatorControl: SessionCoordinator.PlaybackControl {
        switch self {
        case .playPause: return .playPause
        case .seekBack: return .seekBack
        case .seekForward: return .seekForward
        }
    }
}
