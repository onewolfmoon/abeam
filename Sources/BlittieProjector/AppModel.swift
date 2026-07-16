import Foundation
import Observation
import ReceiverProtocol

enum SenderMode: String, CaseIterable, Identifiable {
    case video
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Send Video"
        case .mirror: "Mirror Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "play.rectangle.fill"
        case .mirror: "rectangle.on.rectangle"
        }
    }
}

@Observable
@MainActor
final class AppModel {
    var mode: SenderMode = .video
    var showReceiverSheet = false

    // Polled from `connection` (see startPolling) rather than pushed, so the
    // status dot reflects the actual live WebSocket connection state instead
    // of just "an address is saved" like the old HTTP-based model did.
    private(set) var connectionState: ReceiverConnection.State = .disconnected

    private(set) var receiverEndpoint: ReceiverEndpoint? {
        didSet {
            UserDefaults.standard.set(receiverEndpoint?.persistedString, forKey: "blittieReceiverAddress")
        }
    }

    let connection = ReceiverConnection()
    private var pollTask: Task<Void, Never>?

    var hasReceiver: Bool { receiverEndpoint != nil }
    var receiverName: String { receiverEndpoint?.displayName ?? "No Screen selected" }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "blittieReceiverAddress"),
           let endpoint = ReceiverEndpoint(persistedString: saved) {
            receiverEndpoint = endpoint
            let connection = connection
            Task { await connection.connect(to: endpoint.nwEndpoint) }
        }
        startPolling()
    }

    // Accepts a bare host ("192.168.1.42" or "living-room.local") or a
    // host:port pair, defaulting to the Receiver's fixed control port when
    // none is given.
    @discardableResult
    func connect(to input: String) -> Bool {
        guard let endpoint = ReceiverEndpoint(manualInput: input) else { return false }
        select(endpoint)
        return true
    }

    func select(_ discovered: DiscoveredReceiver) {
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
// one-HTTP-POST-per-call ReceiverClient.
extension AppModel {
    struct NotConnected: Error {}

    @discardableResult
    func sendYouTube(url: String) async throws -> Bool {
        let connection = connection
        switch try await connection.send(.youtube(url: url)) {
        case .ok: return true
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer, .notHandled: return false
        }
    }

    @discardableResult
    func sendControl(_ control: ReceiverControl) async throws -> Bool {
        let connection = connection
        switch try await connection.send(.control(control)) {
        case .ok: return true
        case .notHandled: return false
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer: return false
        }
    }

    @discardableResult
    func sendStop() async throws -> Bool {
        let connection = connection
        switch try await connection.send(.stop) {
        case .ok: return true
        case .notHandled: return false
        case .error(let message): throw ReceiverRequestError(message: message)
        case .answer: return false
        }
    }

    // Used by the mirror flow: sends the locally-created SDP offer and
    // returns the Receiver's SDP answer.
    func sendOffer(sdp: String) async throws -> String {
        let connection = connection
        switch try await connection.send(.offer(sdp: sdp)) {
        case .answer(let sdp): return sdp
        case .error(let message): throw ReceiverRequestError(message: message)
        case .ok, .notHandled: throw ReceiverRequestError(message: "receiver did not return an answer")
        }
    }
}

struct ReceiverRequestError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
