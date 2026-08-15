import Foundation
@preconcurrency import WebRTC

/// A WebRTC screen mirroring session. Instances handle accepting an SDP offer,
/// producing an answer, and connecting over WebRTC.
///
/// SDP exchange happens over WebSocket, so no ICE servers are involved. Trickle
/// ICE is not supported.
@MainActor
final class NativeMirrorSession {
    enum SessionError: Error {
        case invalidOfferJSON
        case noPeerConnection
        case noAnswer
    }

    /// The shape of the JSON payload of an incoming SDP offer.
    private struct WireSessionDescription: Codable {
        let type: String
        let sdp: String
    }

    private let peerConnection: RTCPeerConnection
    private let observer: ConnectionObserver

    /// A reusable connection factory. This factory is safe to share across
    /// sessions.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            // Video is never encoded by Abaft.
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            // Supports up to 1080p video. Not using this factory when Abeam
            // sends video higher resolution than 720p results in a black
            // screen.
            decoderFactory: HighLevelH264DecoderFactory()
        )
    }()

    private init(
        peerConnection: RTCPeerConnection,
        observer: ConnectionObserver
    ) {
        self.peerConnection = peerConnection
        self.observer = observer
    }

    /// Creates an answer to an incoming SDP offer from Abeam.
    static func acceptOffer(_ offerJSON: String) async throws -> (
        session: NativeMirrorSession, answerSDP: String
    ) {
        guard let offerData = offerJSON.data(using: .utf8),
            let decodedOffer = try? JSONDecoder().decode(
                WireSessionDescription.self,
                from: offerData
            )
        else {
            throw SessionError.invalidOfferJSON
        }

        let observer = ConnectionObserver()
        let config = RTCConfiguration()
        // No ICE servers can help with LAN-only connections.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        // Trickle ICE is not supported.
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard
            let peerConnection = factory.peerConnection(
                with: config,
                constraints: constraints,
                delegate: observer
            )
        else {
            throw SessionError.noPeerConnection
        }

        let session = NativeMirrorSession(
            peerConnection: peerConnection,
            observer: observer
        )

        let offer = RTCSessionDescription(type: .offer, sdp: decodedOffer.sdp)
        try await peerConnection.setRemoteDescriptionAsync(offer)

        let answer = try await peerConnection.createAnswerAsync(
            constraints: constraints
        )
        try await peerConnection.setLocalDescriptionAsync(answer)
        await peerConnection.waitForIceGatheringComplete()

        guard let localSDP = peerConnection.localDescription?.sdp,
            let answerData = try? JSONEncoder().encode(
                WireSessionDescription(type: "answer", sdp: localSDP)
            ),
            let answerJSON = String(data: answerData, encoding: .utf8)
        else {
            throw SessionError.noAnswer
        }
        return (session, answerJSON)
    }

    /// A stream that fires once when the first frame of the remote track is
    /// decoded and ready to display.
    var readyEvents: AsyncStream<Void> { observer.readyEvents }

    /// A stream that fires if the connection is disconnected.
    var disconnectedEvents: AsyncStream<Void> { observer.disconnectedEvents }

    /// The remote screen-share video track. This is populated once Abeam's
    /// offer has been accepted.
    var videoTrack: RTCVideoTrack? { observer.videoTrack }

    /// Closes the connection immediately.
    func teardown() {
        peerConnection.close()
    }
}

// MARK: - Async wrappers

/// An extension that bridges RTCPeerConnection's completion handlers to
/// async/await.
extension RTCPeerConnection {
    fileprivate func setRemoteDescriptionAsync(_ sdp: RTCSessionDescription)
        async throws
    {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate func setLocalDescriptionAsync(_ sdp: RTCSessionDescription)
        async throws
    {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate func createAnswerAsync(constraints: RTCMediaConstraints)
        async throws -> RTCSessionDescription
    {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            self.answer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? NativeMirrorSession.SessionError.noAnswer
                    )
                }
            }
        }
    }

    // TODO: Understand why polling is desirable here.

    /// Waits for ICE candidate gathering.
    ///
    /// Use this for one-shot waits. Implemented as polling.
    fileprivate func waitForIceGatheringComplete() async {
        while iceGatheringState != .complete {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

// TODO: Try to understand this paragraph.

// WebRTC invokes these callbacks from its own internal signaling thread, not
// MainActor, so every conformance method here is `nonisolated` and only touches
// state that's safe to mutate from any thread - AsyncStream's Continuation
// (documented Sendable, safe to yield from anywhere) and
// videoTrack/firstFrameSentinel, marked nonisolated(unsafe) — WebRTC's own
// delegate dispatch is serial (never concurrent with itself), and
// NativeMirrorSession only ever reads videoTrack after readyEvents has already
// fired, so this matches the same nonisolated(unsafe) pattern
// SessionCoordinator uses for its cursor-hide timer/monitor.

/// Mutable connection state that is needed before `NativeMirrorSession` is
/// created.
private final class ConnectionObserver: NSObject, RTCPeerConnectionDelegate {
    let readyEvents: AsyncStream<Void>
    let disconnectedEvents: AsyncStream<Void>
    private let readyContinuation: AsyncStream<Void>.Continuation
    private let disconnectedContinuation: AsyncStream<Void>.Continuation

    nonisolated(unsafe) private(set) var videoTrack: RTCVideoTrack?
    private nonisolated(unsafe) var didSignalReady = false
    private let firstFrameSentinel = FirstFrameSentinel()

    override init() {
        var readyContinuation: AsyncStream<Void>.Continuation!
        readyEvents = AsyncStream { readyContinuation = $0 }
        self.readyContinuation = readyContinuation

        var disconnectedContinuation: AsyncStream<Void>.Continuation!
        disconnectedEvents = AsyncStream { disconnectedContinuation = $0 }
        self.disconnectedContinuation = disconnectedContinuation

        super.init()

        firstFrameSentinel.onFirstFrame = { [weak self] in
            self?.signalReady()
        }
    }

    private nonisolated func signalReady() {
        guard !didSignalReady else { return }
        didSignalReady = true
        readyContinuation.yield()
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        track.add(firstFrameSentinel)
    }

    nonisolated func peerConnectionShouldNegotiate(
        _ peerConnection: RTCPeerConnection
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        switch newState {
        case .disconnected, .failed, .closed:
            disconnectedContinuation.yield()
        default:
            break
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {}
}

/// A minimal RTCVideoRenderer that only exists to detect the first decoded
/// frame. This signals readiness independently of any visual renderer
/// NativeMirrorView attaches separately. RTCVideoTrack supports multiple
/// simultaneous renderers, so this doesn't interfere with actual display.
private final class FirstFrameSentinel: NSObject, RTCVideoRenderer {
    nonisolated(unsafe) var onFirstFrame: (() -> Void)?
    private nonisolated(unsafe) var firedOnce = false

    nonisolated func setSize(_ size: CGSize) {}

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil, !firedOnce else { return }
        firedOnce = true
        onFirstFrame?()
    }
}
