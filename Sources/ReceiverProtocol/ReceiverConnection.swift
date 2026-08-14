import Foundation
import Network

/// A WebSocket connection to an Abaft screen. This connection is shared between
/// video playback control and screen mirroring SDP exchange.
public actor ReceiverConnection {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(NWError)
    }

    public enum WireError: Error, Sendable {
        case notConnected
        case connectFailed(NWError)
        case sendFailed(NWError)
        case timedOut
        case invalidResponse
    }

    private let queue = DispatchQueue(label: "ReceiverConnection.nw")
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var pending: [UUID: CheckedContinuation<ResponsePayload, Error>] =
        [:]
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var reconnectAttempt = 0

    public private(set) var state: State = .disconnected {
        didSet {
            for continuation in stateContinuations.values {
                continuation.yield(state)
            }
        }
    }
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] =
        [:]

    public init() {}

    public func stateUpdates() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    public func connect(to endpoint: NWEndpoint) {
        if endpoint == self.endpoint,
            state == .connecting || state == .connected
        {
            return
        }
        self.endpoint = endpoint
        shouldReconnect = true
        reconnectAttempt = 0
        reconnectTask?.cancel()
        connection?.cancel()
        openConnection()
    }

    public func disconnect() {
        shouldReconnect = false
        endpoint = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        state = .disconnected
        failAllPending(WireError.notConnected)
    }

    /// Connects (if needed) and waits until the connection is ready.
    ///
    /// Callers may block on this call to know when it's safe to send().
    public func connectAndWaitUntilReady(
        to endpoint: NWEndpoint,
        timeout: Duration = .seconds(8)
    ) async throws {
        connect(to: endpoint)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            switch state {
            case .connected:
                return
            case .failed(let error):
                throw WireError.connectFailed(error)
            case .connecting, .disconnected:
                break
            }
            guard ContinuousClock.now < deadline else {
                throw WireError.timedOut
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    public func send(_ payload: RequestPayload) async throws -> ResponsePayload
    {
        guard let connection, state == .connected else {
            throw WireError.notConnected
        }
        let request = ReceiverRequest(payload: payload)
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "request",
                metadata: [metadata]
            )
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task {
                        await self?.failPending(
                            id: request.id,
                            error: WireError.sendFailed(error)
                        )
                    }
                }
            )
        }
    }

    private func failPending(id: UUID, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func openConnection() {
        guard let endpoint else { return }
        state = .connecting
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let newConnection = NWConnection(to: endpoint, using: params)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] nwState in
            Task { await self?.handleStateUpdate(nwState) }
        }
        newConnection.start(queue: queue)
        receiveLoop(on: newConnection)
    }

    private func handleStateUpdate(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            reconnectAttempt = 0
            state = .connected
        case .failed(let error):
            state = .failed(error)
            failAllPending(WireError.connectFailed(error))
            scheduleReconnect()
        case .cancelled:
            if state != .disconnected {
                state = .disconnected
                failAllPending(WireError.notConnected)
                scheduleReconnect()
            }
        case .waiting(let error):
            state = .failed(error)
        default:
            break
        }
    }

    /// Try to reconnect with backoff.
    private func scheduleReconnect() {
        guard shouldReconnect, endpoint != nil else { return }
        reconnectAttempt += 1
        let delaySeconds = min(Double(reconnectAttempt) * 1.5, 15)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.retryIfNeeded()
        }
    }

    private func retryIfNeeded() {
        guard shouldReconnect else { return }
        openConnection()
    }

    // This method is `nonisolated` so it can be re-invoked directly from
    // NWConnection's own callback queue without hopping through the actor just
    // to schedule the next receive.
    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage {
            [weak self] content, context, isComplete, error in
            if let content, !content.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleIncoming(content)
                }
                self?.receiveLoop(on: connection)
            } else {
                // An empty read with no error is how NWConnection reports a
                // clean remote close. Explicitly cancelling the connection here
                // triggers this class's cancellation logic.
                connection.cancel()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard
            let response = try? JSONDecoder().decode(
                ReceiverResponse.self,
                from: data
            )
        else { return }
        pending.removeValue(forKey: response.id)?.resume(
            returning: response.payload
        )
    }

    private func failAllPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        for continuation in all.values {
            continuation.resume(throwing: error)
        }
    }
}

extension ReceiverConnection.WireError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the Screen."
        case .connectFailed(let error):
            return error.userFacingDescription
        case .sendFailed(let error):
            return error.userFacingDescription
        case .timedOut:
            return "Connecting to the Screen timed out."
        case .invalidResponse:
            return "Received an unexpected response from the Screen."
        }
    }
}

/// An extension that provides user-facing error description strings.
extension NWError {
    fileprivate var userFacingDescription: String {
        switch self {
        case .posix(.ECONNREFUSED):
            return
                "The Screen refused the connection. Make sure Blittie Screen is running there."
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.ENETDOWN):
            return "Couldn't reach that address on the network."
        case .posix(.ETIMEDOUT):
            return "The connection timed out."
        case .dns:
            return "Couldn't resolve that hostname."
        default:
            return "Couldn't connect to the Screen."
        }
    }
}
