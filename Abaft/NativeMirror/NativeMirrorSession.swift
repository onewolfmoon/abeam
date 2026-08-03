import Foundation
@preconcurrency import WebRTC

// Native analog of vga's receiver.html: accepts an SDP offer, answers it,
// and exposes the incoming screen-share track for NativeMirrorView to
// render — no WebView anywhere in this path. Configuration (no STUN/TURN,
// non-trickle gathering) matches SignalingCore's common.js exactly, and the
// wire protocol's LAN-only trust model. See
// doc/native-mirroring-mdns-spike.md for why this replaces WKWebView here
// specifically: Chrome's mDNS-obfuscated ICE candidates aren't resolved by
// WebKit's WebRTC stack, but are resolved by this — the same libwebrtc
// codebase Chrome itself uses — with no shim needed, confirmed by a spike
// there before this was written.
@MainActor
final class NativeMirrorSession {
    enum SessionError: Error {
        case invalidOfferJSON
        case noPeerConnection
        case noAnswer
    }

    // The wire protocol's "sdp" field isn't raw SDP text — it's whatever
    // JSON.stringify(RTCSessionDescription) produces in mirror.html
    // ({"type":"...","sdp":"..."}). receiver.html always JSON.parse'd the
    // offer and JSON.stringify'd the answer for exactly this reason; this is
    // the native equivalent of that unwrap/rewrap, not an SDP construct of
    // its own.
    private struct WireSessionDescription: Codable {
        let type: String
        let sdp: String
    }

    private let peerConnection: RTCPeerConnection
    private let observer: ConnectionObserver

    // Created once and reused: RTCPeerConnectionFactory is expensive to
    // construct repeatedly and is safe to share across sessions.
    // decoderFactory: HighLevelH264DecoderFactory rather than the plain
    // default — see that type's doc comment for why a bare
    // RTCPeerConnectionFactory() can never negotiate a common codec against
    // Abaft's offer and hangs this session forever waiting on ICE gathering
    // that never completes.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: HighLevelH264DecoderFactory()
        )
    }()

    private init(peerConnection: RTCPeerConnection, observer: ConnectionObserver) {
        self.peerConnection = peerConnection
        self.observer = observer
    }

    // Sets the remote offer, creates+sets an answer, and waits for ICE
    // gathering to finish before returning it — the non-trickle contract
    // common.js's waitForIceGatheringComplete already establishes on the
    // Sender side, so the returned answer is one self-contained SDP blob,
    // matching receiver.html's acceptOffer.
    static func acceptOffer(_ offerJSON: String) async throws -> (session: NativeMirrorSession, answerSDP: String) {
        guard let offerData = offerJSON.data(using: .utf8),
              let decodedOffer = try? JSONDecoder().decode(WireSessionDescription.self, from: offerData) else {
            throw SessionError.invalidOfferJSON
        }

        let observer = ConnectionObserver()
        let config = RTCConfiguration()
        // Matches common.js's createPeerConnection: LAN-only, no STUN/TURN.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        // Non-trickle, matching waitForIceGatheringComplete below.
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: observer) else {
            throw SessionError.noPeerConnection
        }

        let session = NativeMirrorSession(peerConnection: peerConnection, observer: observer)

        let offer = RTCSessionDescription(type: .offer, sdp: decodedOffer.sdp)
        try await peerConnection.setRemoteDescriptionAsync(offer)

        let answer = try await peerConnection.createAnswerAsync(constraints: constraints)
        try await peerConnection.setLocalDescriptionAsync(answer)
        await peerConnection.waitForIceGatheringComplete()

        guard let localSDP = peerConnection.localDescription?.sdp,
              let answerData = try? JSONEncoder().encode(WireSessionDescription(type: "answer", sdp: localSDP)),
              let answerJSON = String(data: answerData, encoding: .utf8) else {
            throw SessionError.noAnswer
        }
        return (session, answerJSON)
    }

    // Fires once the first frame of the remote track has actually been
    // decoded and is ready to display — a more precise readiness signal
    // than receiver.html's <video> 'playing' event equivalent.
    var readyEvents: AsyncStream<Void> { observer.readyEvents }

    // Fires when the connection drops for any reason (Sender ended the
    // session, network loss, etc.), matching receiver.html's
    // connectionstatechange handler.
    var disconnectedEvents: AsyncStream<Void> { observer.disconnectedEvents }

    // The remote screen-share video track, once the Sender's offer has been
    // accepted. In practice already set by the time acceptOffer returns —
    // WebRTC reports the receiver during setRemoteDescription's own
    // processing, before its completion handler (and so our continuation)
    // fires — but NativeMirrorView re-checks this in updateNSView too, in
    // case that ordering ever isn't guaranteed by a future WebRTC version.
    var videoTrack: RTCVideoTrack? { observer.videoTrack }

    // Closes the connection immediately, matching receiver.html's
    // window.__blittieTeardown — called right before the hosting window
    // closes so the Sender sees a clean DTLS close instead of waiting out
    // an ICE consent-timeout.
    func teardown() {
        peerConnection.close()
    }
}

// MARK: - Async wrappers

// RTCPeerConnection's API is completion-handler based; these bridge it to
// async/await for NativeMirrorSession's use above.
private extension RTCPeerConnection {
    // Named distinctly from the underlying completion-handler methods
    // (rather than overloading the same name) — sharing a name with the
    // method being called from inside the wrapper's own body confused the
    // type checker into an internal "failed to produce diagnostic" error.
    func setRemoteDescriptionAsync(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setLocalDescriptionAsync(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func createAnswerAsync(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            self.answer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? NativeMirrorSession.SessionError.noAnswer)
                }
            }
        }
    }

    // Polling rather than the icegatheringstatechange-equivalent delegate
    // callback: this is a short-lived, one-shot wait (LAN host candidates
    // only, no STUN round-trip) and keeping it self-contained here avoids
    // threading a continuation through ConnectionObserver for a single call
    // site.
    func waitForIceGatheringComplete() async {
        while iceGatheringState != .complete {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

// Holds all mutable connection state and delegate conformance. Kept
// separate from NativeMirrorSession itself because
// RTCPeerConnectionFactory.peerConnection(with:constraints:delegate:)
// requires the delegate at construction time, before a session object
// could exist to be its own delegate.
//
// WebRTC invokes these callbacks from its own internal signaling thread,
// not MainActor, so every conformance method here is `nonisolated` and only
// touches state that's safe to mutate from any thread: AsyncStream's
// Continuation (documented Sendable, safe to yield from anywhere) and
// videoTrack/firstFrameSentinel, marked nonisolated(unsafe) — WebRTC's own
// delegate dispatch is serial (never concurrent with itself), and
// NativeMirrorSession only ever reads videoTrack after readyEvents has
// already fired, so this matches the same nonisolated(unsafe) pattern
// vga's own SessionCoordinator uses for its cursor-hide timer/monitor.
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

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    // Unified Plan's actual track-arrival callback (didAdd stream: above is
    // the legacy Plan B equivalent, kept only because it's a required
    // protocol method).
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        track.add(firstFrameSentinel)
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .disconnected, .failed, .closed:
            disconnectedContinuation.yield()
        default:
            break
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// A minimal RTCVideoRenderer that only exists to detect the first decoded
// frame — the readiness signal — independent of whatever visual renderer
// NativeMirrorView attaches separately. RTCVideoTrack supports multiple
// simultaneous renderers, so this doesn't interfere with actual display.
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
