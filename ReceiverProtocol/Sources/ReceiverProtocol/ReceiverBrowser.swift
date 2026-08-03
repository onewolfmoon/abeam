import Foundation
import Network

public struct DiscoveredReceiver: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

// Sender-side Bonjour discovery. Connecting to a result doesn't need a
// resolve step first — NWConnection resolves an NWEndpoint.service directly
// as part of connecting (see ReceiverEndpoint.nwEndpoint) — so this only
// needs to surface names for the picker UI.
public actor ReceiverBrowser {
    public private(set) var results: [DiscoveredReceiver] = [] {
        didSet { for continuation in resultContinuations.values { continuation.yield(results) } }
    }
    private var resultContinuations: [UUID: AsyncStream<[DiscoveredReceiver]>.Continuation] = [:]

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "ReceiverBrowser.nw")

    public init() {}

    // Pushes every results update, starting with the current value, so
    // callers (e.g. ReceiverPickerSheet) can observe discoveries as they
    // arrive instead of polling — matching ReceiverConnection.stateUpdates().
    public func resultsUpdates() -> AsyncStream<[DiscoveredReceiver]> {
        AsyncStream { continuation in
            let id = UUID()
            resultContinuations[id] = continuation
            continuation.yield(results)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeResultContinuation(id) }
            }
        }
    }

    private func removeResultContinuation(_ id: UUID) {
        resultContinuations.removeValue(forKey: id)
    }

    public func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjour(type: ReceiverEndpoint.serviceType, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: .tcp)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let receivers: [DiscoveredReceiver] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredReceiver(name: name)
            }.sorted { $0.name < $1.name }
            Task { await self?.publish(receivers) }
        }
        newBrowser.start(queue: queue)
        browser = newBrowser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        results = []
    }

    private func publish(_ receivers: [DiscoveredReceiver]) {
        results = receivers
    }
}
