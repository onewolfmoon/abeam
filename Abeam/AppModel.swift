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

    // Excludes .mirror where ScreenCaptureKit-backed mirroring isn't
    // available: platforms without the module at all, or devices running
    // below its iOS 27 minimum (e.g. iOS 26).
    static var availableCases: [SenderMode] {
        #if canImport(ScreenCaptureKit)
            if #available(iOS 27, *) {
                return allCases
            } else {
                return allCases.filter { $0 != .mirror }
            }
        #else
            return allCases.filter { $0 != .mirror }
        #endif
    }
}

@Observable
@MainActor
final class AppModel {
    var mode: SenderMode = .video
    var showReceiverSheet = false

    private(set) var connectionState: ReceiverConnection.State = .disconnected

    private(set) var receiverEndpoint: ReceiverEndpoint? {
        didSet { ReceiverEndpointStore.current = receiverEndpoint }
    }

    let connection = ReceiverConnection()
    private var observeStateTask: Task<Void, Never>?

    var hasReceiver: Bool { receiverEndpoint != nil }
    var receiverName: String {
        receiverEndpoint?.displayName ?? "No Screen selected"
    }

    init() {
        if let endpoint = ReceiverEndpointStore.current {
            receiverEndpoint = endpoint
            let connection = connection
            Task { await connection.connect(to: endpoint.nwEndpoint) }
        }
        observeState()
    }

    /// Connects to a user-specified Abaft screen by address.
    ///
    /// * Accepts IP addresses.
    /// * Accepts hostnames, including mDNS hostnames (`*.local`).
    /// * Accepts addresses with ports, defaulting to `defaultWSSPort` if
    ///   omitted.
    @discardableResult
    func connect(to input: String) -> Bool {
        guard let endpoint = ReceiverEndpoint(manualInput: input) else {
            return false
        }
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

/// Lifecycle-aware wrappers over the shared persistent connection.
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

    /// Sends the locally-created SDP offer and returns the Abaft's SDP answer.
    func sendOffer(sdp: String) async throws -> String {
        let connection = connection
        switch try await connection.send(.offer(sdp: sdp)) {
        case .answer(let sdp): return sdp
        case .error(let message): throw ReceiverRequestError(message: message)
        case .ok, .notHandled:
            throw ReceiverRequestError(
                message: "receiver did not return an answer"
            )
        }
    }
}

struct ReceiverRequestError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
