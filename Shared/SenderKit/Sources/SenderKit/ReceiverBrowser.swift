import Foundation
import Network

public struct DiscoveredReceiver: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

// Bonjour discovery. Connecting to a result doesn't need a resolve step
// first — NWConnection resolves an NWEndpoint.service directly as part of
// connecting (see ReceiverEndpoint.nwEndpoint) — so this only needs to
// surface names for the picker UI.
public actor ReceiverBrowser {
    // Polled by callers (matching ReceiverConnection.state) rather than
    // pushed via a handler closure.
    public private(set) var results: [DiscoveredReceiver] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "ReceiverBrowser.nw")

    public init() {}

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
