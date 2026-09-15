import Foundation
import Network
import ReceiverProtocol

/// A server that serves the the Bonjour advertisement and the WebSocket server.
/// The Bonjour advertisement allows Abeam to discover this Abaft screen, and
/// the WebSocket server is used for WebRTC negotiation and video playback
/// control.
actor ReceiverSocketServer {
    private let coordinator: SessionCoordinator
    private let info: ReceiverServerInfo
    private var listener: NWListener?
    private var activeSessionConnection: NWConnection?
    private let queue = DispatchQueue(label: "ReceiverSocketServer.nw")

    private init(coordinator: SessionCoordinator, info: ReceiverServerInfo) {
        self.coordinator = coordinator
        self.info = info
    }

    @discardableResult
    static func start(
        coordinator: SessionCoordinator,
        info: ReceiverServerInfo
    ) -> ReceiverSocketServer {
        let server = ReceiverSocketServer(coordinator: coordinator, info: info)
        Task { await server.start() }
        return server
    }

    private func start() {
        startPlainListener()
    }

    private func startPlainListener() {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        // Bind an OS-assigned port rather than a fixed one. Bonjour
        // advertises whichever port the listener actually binds to, so
        // Abeam's discovered connections aren't affected; manual
        // connections need the port shown in Abaft's settings.
        guard let listener = try? NWListener(using: params, on: .any) else {
            FileHandle.standardError.write(
                Data("Receiver socket server failed to bind a port\n".utf8)
            )
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
        let info = info
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue {
                    Task { @MainActor in info.setPort(port) }
                }
            case .failed(let error):
                FileHandle.standardError.write(
                    Data("Receiver socket server (ws) failed: \(error)\n".utf8)
                )
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
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

    // `nonisolated` so the recursive re-receive can be scheduled directly from
    // NWConnection's own callback queue without an actor hop; only the decoded
    // message handling below touches actor state.
    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage {
            [weak self] content, context, isComplete, error in
            if let content, !content.isEmpty {
                Task { await self?.handle(content, from: connection) }
                self?.receiveLoop(on: connection)
            } else {
                // When the peer closes the connection, that can manifest as an
                // empty read. Handle empty reads with explicit cancellation so
                // that the cancellation logic runs.
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) async {
        guard
            let request = try? JSONDecoder().decode(
                ReceiverRequest.self,
                from: data
            )
        else { return }
        let responsePayload = await process(request.payload, from: connection)
        send(
            ReceiverResponse(id: request.id, payload: responsePayload),
            on: connection
        )
    }

    private func process(
        _ payload: RequestPayload,
        from connection: NWConnection
    ) async -> ResponsePayload {
        switch payload {
        case .video(let sharePayload):
            // Let each parser attempt to parse this share payload for a URL.
            guard await coordinator.startVideo(payload: sharePayload) else {
                return .error(message: "no video parser recognized this link")
            }
            preempt(newOwner: connection)
            return .ok

        case .offer(let sdp):
            preempt(newOwner: connection)
            do {
                let answer = try await coordinator.startOffer(sdp)
                return .answer(sdp: answer)
            } catch {
                return .error(message: "\(error)")
            }

        case .control(let control):
            let handled = await coordinator.sendControl(
                control.sessionCoordinatorControl
            )
            return handled ? .ok : .notHandled

        case .stop:
            let handled = await coordinator.stop()
            return handled ? .ok : .notHandled

        case .displayOn:
            await coordinator.turnDisplayOn()
            return .ok

        case .displayOff:
            await coordinator.turnDisplayOff()
            return .ok
        }
    }

    private func preempt(newOwner connection: NWConnection) {
        if let activeSessionConnection, activeSessionConnection !== connection {
            activeSessionConnection.cancel()
        }
        activeSessionConnection = connection
    }

    private nonisolated func send(
        _ response: ReceiverResponse,
        on connection: NWConnection
    ) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "response",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}

extension ReceiverControl {
    fileprivate var sessionCoordinatorControl:
        SessionCoordinator.PlaybackControl
    {
        switch self {
        case .playPause: return .playPause
        case .seekBack: return .seekBack
        case .seekForward: return .seekForward
        }
    }
}
