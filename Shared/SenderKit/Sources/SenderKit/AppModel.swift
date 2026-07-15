import Foundation
import Observation

@Observable
@MainActor
public final class AppModel {
    // Polled from `connection` (see startPolling) rather than pushed, so the
    // status dot reflects the actual live WebSocket connection state instead
    // of just "an address is saved" like the old HTTP-based model did.
    public private(set) var connectionState: ReceiverConnection.State = .disconnected

    public private(set) var receiverEndpoint: ReceiverEndpoint? {
        didSet { ReceiverAddressStore.endpoint = receiverEndpoint }
    }

    public let connection = ReceiverConnection()
    private var pollTask: Task<Void, Never>?

    public var hasReceiver: Bool { receiverEndpoint != nil }
    public var receiverName: String { receiverEndpoint?.displayName ?? "No receiver selected" }

    public init() {
        if let saved = ReceiverAddressStore.endpoint {
            receiverEndpoint = saved
            let connection = connection
            Task { await connection.connect(to: saved.nwEndpoint) }
        }
        startPolling()
    }

    // Accepts a bare host ("192.168.1.42" or "living-room.local") or a
    // host:port pair, defaulting to the Receiver's fixed control port when
    // none is given.
    @discardableResult
    public func connect(to input: String) -> Bool {
        guard let endpoint = ReceiverEndpoint(manualInput: input) else { return false }
        select(endpoint)
        return true
    }

    public func select(_ discovered: DiscoveredReceiver) {
        select(.bonjour(name: discovered.name))
    }

    private func select(_ endpoint: ReceiverEndpoint) {
        receiverEndpoint = endpoint
        let connection = connection
        Task { await connection.connect(to: endpoint.nwEndpoint) }
    }

    private func startPolling() {
        pollTask?.cancel()
        let connection = connection
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let state = await connection.state
                guard let self, !Task.isCancelled else { return }
                if self.connectionState != state {
                    self.connectionState = state
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}

// Thin wrappers over the shared persistent connection, replacing the old
// one-HTTP-POST-per-call ControlClient.
extension AppModel {
    @discardableResult
    public func sendYouTube(url: String) async throws -> Bool {
        switch try await connection.send(.youtube(url: url)) {
        case .ok: return true
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer, .notHandled: return false
        }
    }

    @discardableResult
    public func sendControl(_ control: ReceiverControl) async throws -> Bool {
        switch try await connection.send(.control(control)) {
        case .ok: return true
        case .notHandled: return false
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer: return false
        }
    }

    @discardableResult
    public func sendStop() async throws -> Bool {
        switch try await connection.send(.stop) {
        case .ok: return true
        case .notHandled: return false
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer: return false
        }
    }
}

public struct ReceiverRequestError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}
