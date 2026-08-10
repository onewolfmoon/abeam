import Foundation
import MirrorKit
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
        case .video: "play.rectangle"
        case .mirror: "rectangle.on.rectangle"
        }
    }

    // Excludes .mirror on platforms where MirrorKit's ScreenCaptureKit-backed
    // types aren't available (iOS below 27) — see MirrorKit.isScreenMirroringSupported.
    static var availableCases: [SenderMode] {
        allCases.filter { $0 != .mirror || MirrorKit.isScreenMirroringSupported }
    }
}

@Observable
@MainActor
final class AppModel {
    var mode: SenderMode = .video
    var showReceiverSheet = false

    // Pushed from `connection.stateUpdates()` so the status dot reflects the
    // actual live WebSocket connection state instead of just "an address is
    // saved".
    private(set) var connectionState: ReceiverConnection.State = .disconnected

    private(set) var receiverEndpoint: ReceiverEndpoint? {
        didSet { ReceiverEndpointStore.current = receiverEndpoint }
    }

    let connection = ReceiverConnection()
    private var observeStateTask: Task<Void, Never>?

    var hasReceiver: Bool { receiverEndpoint != nil }
    var receiverName: String { receiverEndpoint?.displayName ?? "No Screen selected" }

    init() {
        if let endpoint = ReceiverEndpointStore.current {
            receiverEndpoint = endpoint
            let connection = connection
            Task { await connection.connect(to: endpoint.nwEndpoint) }
        }
        observeState()
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

    private func observeState() {
        observeStateTask?.cancel()
        let connection = connection
        observeStateTask = Task { [weak self] in
            for await state in await connection.stateUpdates() {
                guard let self, !Task.isCancelled else { return }
                self.connectionState = state
            }
        }
    }
}

// Thin wrappers over the shared persistent connection.
extension AppModel {
    struct NotConnected: Error {}

    @discardableResult
    func sendVideo(payload: String) async throws -> Bool {
        let connection = connection
        switch try await connection.send(.video(payload: payload)) {
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
