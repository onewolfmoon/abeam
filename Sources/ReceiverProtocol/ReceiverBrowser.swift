import Foundation
import Network

public struct DiscoveredReceiver: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// A Bonjour browser for discovering Abaft screens from Abeam.
public actor ReceiverBrowser {
    public private(set) var results: [DiscoveredReceiver] = [] {
        didSet {
            for continuation in resultContinuations.values {
                continuation.yield(results)
            }
        }
    }
    private var resultContinuations:
        [UUID: AsyncStream<[DiscoveredReceiver]>.Continuation] = [:]

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "ReceiverBrowser.nw")

    public init() {}

    /// Pushes an array of Abaft screens when the list of discovered screens
    /// updates.
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
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: ReceiverEndpoint.serviceType,
            domain: nil
        )
        let newBrowser = NWBrowser(for: descriptor, using: .tcp)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let receivers: [DiscoveredReceiver] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else {
                    return nil
                }
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
