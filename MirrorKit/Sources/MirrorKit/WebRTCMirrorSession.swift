import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import WebRTC
import CoreMedia

public enum MirrorSessionError: Error, Sendable {
    case failedToCreatePeerConnection
    case notMirroring
}

// The wire protocol's "sdp" field isn't actually bare SDP text — it's a
// JSON-encoded {type, sdp} object (what browsers get for free from
// JSON.stringify(pc.localDescription)/RTCSessionDescription's toJSON),
// carried as a string. receiver.html's acceptOffer(offerJson) does
// JSON.parse(offerJson) expecting exactly this shape before handing it to
// setRemoteDescription. Established by mirror.html's __blittieCreateOffer/
// __blittieApplyAnswer, which this native path has to match since Blittie
// Screen isn't changing.
private struct WireSessionDescription: Codable {
    let type: String
    let sdp: String
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
//
// iOS 27 minimum: takes an SCContentFilter and drives a ScreenCaptureSession,
// both iOS-27-gated (see MirrorKit's Package.swift comment).
@available(iOS 27, *)
public actor WebRTCMirrorSession: NSObject, RTCPeerConnectionDelegate {
    public enum ConnectionState: Sendable, Equatable {
        case new, connecting, connected, disconnected, failed, closed
    }

    // HighLevelH264EncoderFactory instead of RTCDefaultVideoEncoderFactory:
    // the latter's H264 entries hardcode profile-level-id at Level 3.1,
    // whose 3600-macroblock cap is below what 1920x1080 needs (8160) —
    // VTCompressionSession silently produces zero output past that cap. See
    // that factory's doc comment for the full story. Decoder side is
    // unaffected (Abeam only ever sends video, never decodes), so
    // RTCDefaultVideoDecoderFactory stays as-is.
    private let factory = RTCPeerConnectionFactory(
        encoderFactory: HighLevelH264EncoderFactory(),
        decoderFactory: RTCDefaultVideoDecoderFactory()
    )
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

        // addTransceiver(with:) alone (no stream id) produces "a=msid:-
        // video0" — stream id "-", RFC 8830's marker for "no associated
        // MediaStream". receiver.html's 'track' handler does
        // remoteVideo.srcObject = event.streams[0], which silently becomes
        // undefined when the track isn't in a real stream — decoding still
        // works, nothing ever reaches the <video> element. streamIds
        // restores a real stream id.
        // No codec-preference filtering needed here: HighLevelH264EncoderFactory
        // only ever advertises the one H264 profile, so there's no ambiguity
        // to resolve the way there was when RTCDefaultVideoEncoderFactory's
        // rtpSenderCapabilities offered H264/VP8/VP9/AV1 all at once.
        //
        // direction = .sendOnly matters now in a way it didn't before:
        // a default sendrecv transceiver needs setLocalDescription to
        // resolve *receive* parameters too, which means matching the
        // offered codec against what RTCDefaultVideoDecoderFactory (still
        // the stock, Level-3.1-only decoder factory — only the encoder
        // side was swapped) can decode. Level 4.0 vs the decoder's Level
        // 3.1 codec list don't match, so setLocalDescription fails outright
        // — "Failed to set local video description recv parameters" — with
        // Abeam never even having sent an offer to Screen yet. Abeam never
        // receives video, so sendOnly sidesteps that negotiation entirely
        // instead of also having to keep the decoder factory in sync.
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["mirror0"]
        if peerConnection.addTransceiver(with: videoTrack, init: transceiverInit) == nil {
            _ = peerConnection.add(videoTrack, streamIds: ["mirror0"])
        }

        let captureSession = ScreenCaptureSession(onSampleBuffer: { sampleBuffer in
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            // Not sampleBuffer.presentationTimeStamp: SCStream's PTS is on
            // the host-time clock, a different epoch/rate than whatever
            // clock WebRTC's internal pacer validates frame timestamps
            // against — a clock mismatch silently drops every frame with
            // no error anywhere. DispatchTime's uptime clock matches what
            // working custom-capturer implementations use.
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
            videoSource.capturer(videoCapturer, didCapture: frame)
        })
        self.captureSession = captureSession
        // Default 1920x1080 — HighLevelH264EncoderFactory's Level 4.0 covers
        // it, unlike the stock factory's Level 3.1 that forced a 1280x720 cap.
        try await captureSession.start(filter: filter)

        let offer = try await peerConnection.offer(for: constraints)
        try await peerConnection.setLocalDescription(offer)
        await waitForIceGatheringComplete(peerConnection)

        guard let localDescription = peerConnection.localDescription else {
            throw MirrorSessionError.failedToCreatePeerConnection
        }
        let wireOffer = WireSessionDescription(type: "offer", sdp: localDescription.sdp)
        return String(decoding: try JSONEncoder().encode(wireOffer), as: UTF8.self)
    }

    public func applyAnswer(sdp: String) async throws {
        guard let peerConnection else { throw MirrorSessionError.notMirroring }
        let wireAnswer = try JSONDecoder().decode(WireSessionDescription.self, from: Data(sdp.utf8))
        try await peerConnection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: wireAnswer.sdp))
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
