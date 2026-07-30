@preconcurrency import ScreenCaptureKit
@preconcurrency import WebRTC
import CoreMedia

public enum MirrorSessionError: Error, Sendable {
    case failedToCreatePeerConnection
    case notMirroring
}

// Bridges a ScreenCaptureSession's frames into a WebRTC RTCPeerConnection.
// No STUN/TURN (LAN-only, empty iceServers, matching Blittie's existing
// trust model) and no trickle ICE: startMirroring waits for ICE gathering
// to finish and returns one self-contained SDP blob, the same shape
// AppModel.sendOffer(sdp:)/receiver.html's WebRTC already expect — the wire
// protocol doesn't need to know or care that the offer came from native
// WebRTC instead of a browser's RTCPeerConnection this time.
//
// An actor for the same reason as ScreenPicker/ScreenCaptureSession:
// RTCPeerConnectionDelegate callbacks land on WebRTC's own signaling
// thread, not the caller's context.
public actor WebRTCMirrorSession: NSObject, RTCPeerConnectionDelegate {
    public enum ConnectionState: Sendable, Equatable {
        case new, connecting, connected, disconnected, failed, closed
    }

    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var captureSession: ScreenCaptureSession?
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

    override public init() {
        super.init()
    }

    // Must be called before startMirroring to observe every state change;
    // matching ReceiverConnection.stateUpdates()'s push-not-poll shape.
    public func connectionStates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            self.stateContinuation = continuation
        }
    }

    public func startMirroring(filter: SCContentFilter) async throws -> String {
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])

        guard let peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw MirrorSessionError.failedToCreatePeerConnection
        }
        self.peerConnection = peerConnection

        let videoSource = factory.videoSource(forScreenCast: true)
        let videoCapturer = RTCVideoCapturer(delegate: videoSource)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        _ = peerConnection.add(videoTrack, streamIds: ["mirror0"])

        let captureSession = ScreenCaptureSession(onSampleBuffer: { sampleBuffer in
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let seconds = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: Int64(seconds * 1_000_000_000))
            videoSource.capturer(videoCapturer, didCapture: frame)
        })
        self.captureSession = captureSession
        try await captureSession.start(filter: filter)

        let offer = try await peerConnection.offer(for: constraints)
        try await peerConnection.setLocalDescription(offer)
        await waitForIceGatheringComplete(peerConnection)

        guard let localDescription = peerConnection.localDescription else {
            throw MirrorSessionError.failedToCreatePeerConnection
        }
        return localDescription.sdp
    }

    public func applyAnswer(sdp: String) async throws {
        guard let peerConnection else { throw MirrorSessionError.notMirroring }
        try await peerConnection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    public func stop() async {
        peerConnection?.close()
        peerConnection = nil
        try? await captureSession?.stop()
        captureSession = nil
        stateContinuation?.finish()
    }

    private func waitForIceGatheringComplete(_ peerConnection: RTCPeerConnection) async {
        if peerConnection.iceGatheringState == .complete { return }
        await withCheckedContinuation { continuation in
            self.iceGatheringContinuation = continuation
        }
    }

    private func resolveIceGathering() {
        iceGatheringContinuation?.resume()
        iceGatheringContinuation = nil
    }

    private func publish(_ state: ConnectionState) {
        stateContinuation?.yield(state)
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { await self.resolveIceGathering() }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let state: ConnectionState
        switch newState {
        case .new: state = .new
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        @unknown default: state = .failed
        }
        Task { await self.publish(state) }
    }
}
