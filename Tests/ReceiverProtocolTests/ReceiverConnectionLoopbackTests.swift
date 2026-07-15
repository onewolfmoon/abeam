import Foundation
import Network
import Testing
@testable import ReceiverProtocol

// Formalizes the manual loopback spike done while designing this refactor:
// confirms NWListener + NWProtocolWebSocket.Options completes the WS
// handshake and frames messages automatically against a ReceiverConnection
// client, and that connecting via a freshly-built NWEndpoint.service (no
// prior NWBrowser browse) resolves and connects correctly.
//
// Uses .service endpoints throughout rather than plain hostPort: an
// interactive spike found that bare hostPort connections from an unsigned,
// bundle-less process were unreliable (macOS's local network privacy
// handling appears to treat Bonjour-mediated connections differently from
// raw-IP ones for such processes), while .service connections were not.
// `swift test`'s runner is exactly that kind of unsigned, bundle-less
// process, so these tests stick to the path proven reliable there — manual
// hostPort connectivity is verified separately against the real signed
// BlittieProjector.app/BlittieScreen.app bundles.
struct ReceiverConnectionLoopbackTests {
    private static let testServiceType = "_blittie-screenprotocol-test._tcp"
    private static let testServiceDomain = "local."

    private func testParameters() -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return params
    }

    private func testEndpoint(_ serviceName: String) -> NWEndpoint {
        .service(name: serviceName, type: Self.testServiceType, domain: Self.testServiceDomain, interface: nil)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TimeoutWaitingForCondition()
    }

    @Test func sendReceivesCorrelatedResponse() async throws {
        let serviceName = "echo-test-\(UUID().uuidString)"
        let listener = try NWListener(using: testParameters())
        listener.service = NWListener.Service(name: serviceName, type: Self.testServiceType, domain: Self.testServiceDomain)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            startReceiveLoop(on: connection) { content in
                respondOK(to: content, on: connection)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }

        let connection = ReceiverConnection()
        await connection.connect(to: testEndpoint(serviceName))
        try await waitUntil { await connection.state == .connected }

        let response = try await connection.send(.stop)
        #expect(response == .ok)

        await connection.disconnect()
    }

    // Mirrors ReceiverSocketServer's preemption rule directly (a new
    // connection sending a message displaces whichever connection was
    // previously "active"), at the transport level only — the actual
    // SessionCoordinator teardown this triggers in the real server is
    // pre-existing, already-covered behavior, not something this test needs
    // to re-verify. Every message still gets a real reply (matching the real
    // server) since ReceiverConnection.send always waits on a correlated
    // response — a fake server that drops messages on the floor makes send()
    // hang forever rather than fail, which is exactly what happened here
    // during development.
    @Test func newConnectionPreemptsPriorActiveConnection() async throws {
        let serviceName = "preempt-test-\(UUID().uuidString)"

        actor ActiveConnectionTracker {
            private var active: NWConnection?
            func markActiveAndPreemptPrevious(_ connection: NWConnection) {
                if let active, active !== connection {
                    active.cancel()
                }
                active = connection
            }
        }
        let tracker = ActiveConnectionTracker()

        let listener = try NWListener(using: testParameters())
        listener.service = NWListener.Service(name: serviceName, type: Self.testServiceType, domain: Self.testServiceDomain)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            startReceiveLoop(on: connection) { content in
                Task { await tracker.markActiveAndPreemptPrevious(connection) }
                respondOK(to: content, on: connection)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }

        let endpoint = testEndpoint(serviceName)

        let clientA = ReceiverConnection()
        await clientA.connect(to: endpoint)
        try await waitUntil { await clientA.state == .connected }
        _ = try await clientA.send(.stop)
        try await Task.sleep(for: .milliseconds(200))

        let clientB = ReceiverConnection()
        await clientB.connect(to: endpoint)
        try await waitUntil { await clientB.state == .connected }
        _ = try await clientB.send(.stop)

        try await waitUntil { await clientA.state != .connected }

        await clientA.disconnect()
        await clientB.disconnect()
    }
}

private struct TimeoutWaitingForCondition: Error {}

// File-scope (not a locally-nested closure-captured func) so the recursive
// self-reference doesn't need an explicit @Sendable annotation to satisfy
// NWConnection.receiveMessage's escaping closure requirement.
private func startReceiveLoop(on connection: NWConnection, onMessage: @escaping @Sendable (Data) -> Void) {
    connection.receiveMessage { content, _, _, error in
        if let content, !content.isEmpty {
            onMessage(content)
        }
        if error == nil {
            startReceiveLoop(on: connection, onMessage: onMessage)
        }
    }
}

private func respondOK(to requestData: Data, on connection: NWConnection) {
    guard let request = try? JSONDecoder().decode(ReceiverRequest.self, from: requestData) else { return }
    let response = ReceiverResponse(id: request.id, payload: .ok)
    guard let responseData = try? JSONEncoder().encode(response) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
    connection.send(content: responseData, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
}
