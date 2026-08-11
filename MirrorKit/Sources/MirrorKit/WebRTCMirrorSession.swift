// Guarded because ScreenCaptureKit isn't in every iOS SDK this target has to
// build against (iOS 27+ only) — see MirrorKit's Package.swift comment and
// MirrorKit.isScreenMirroringSupported. Toolchains without the module simply
// don't compile this file's WebRTC bridge at all.
#if canImport(ScreenCaptureKit)
import Foundation
import MirrorKitAudioBridge
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
    //
    // audioDevice: ScreenAudioDevice instead of the default ADM: without it,
    // an audio track here would open the microphone via RTCAudioSession —
    // ScreenAudioDevice instead feeds it ScreenCaptureKit's captured
    // system/app audio. See its doc comment for the full story.
    private let factory: RTCPeerConnectionFactory
    private let audioDevice: ScreenAudioDevice
    private var peerConnection: RTCPeerConnection?
    private var captureSession: ScreenCaptureSession?
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

    override public init() {
        let audioDevice = ScreenAudioDevice()
        self.audioDevice = audioDevice
        self.factory = MirrorKitMakePeerConnectionFactory(
            HighLevelH264EncoderFactory(),
            RTCDefaultVideoDecoderFactory(),
            audioDevice
        )
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
        addSendOnlyTrack(videoTrack, streamId: "mirror0", to: peerConnection)

        // A different stream id from video ("mirror0-audio", not "mirror0")
        // is deliberate, not an oversight: tracks sharing one MediaStream/
        // msid are exactly what tells WebRTC's own playout-synchronization
        // logic (RtpStreamsSynchronizer) to lip-sync their playout timing
        // against each other. That's right for a recorded call, but wrong
        // here — video's own capture/encode/decode/render pipeline has
        // meaningfully higher and more variable latency than audio's, and
        // forcing audio to track it (rather than each playing out at its own
        // minimum latency) works against a live, as-realtime-as-possible
        // mirror. This does cost the one-line receiver.html convenience of
        // remoteVideo.srcObject = event.streams[0] picking up both tracks at
        // once (untested/unconfirmed whether that receiver path is even
        // live right now) — a real receiver now needs to attach the audio
        // track itself, same as Abaft's native receiver already has to.
        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        let audioTransceiver = addSendOnlyTrack(audioTrack, streamId: "mirror0-audio", to: peerConnection)

        // Ensures audio's RTP packets never queue behind video's bursty
        // sends (e.g. H264 keyframes) on the shared transport — WebRTC's
        // lever for relative scheduling priority between senders sharing
        // one transport.
        if let audioSender = audioTransceiver?.sender {
            let parameters = audioSender.parameters
            for encoding in parameters.encodings {
                encoding.networkPriority = .high
            }
            audioSender.parameters = parameters
        }

        let audioDevice = self.audioDevice
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
        }, onAudioSampleBuffer: { sampleBuffer in
            audioDevice.deliverAudioSampleBuffer(sampleBuffer)
        })
        self.captureSession = captureSession
        // Output size is derived from `filter` itself (see
        // ScreenCaptureSession.captureOutputSize), scaled down as needed to
        // fit HighLevelH264EncoderFactory's Level 4.0 — unlike the stock
        // factory's Level 3.1, which forced a 1280x720 cap regardless.
        try await captureSession.start(filter: filter)

        // kRTCMediaConstraintsVoiceActivityDetection off, not the default
        // (on): VAD is tuned for human speech, and this is system/app audio
        // — music, UI sounds, arbitrary content — with different spectral/
        // energy characteristics a speech-tuned VAD could easily misjudge.
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueFalse],
            optionalConstraints: nil
        )
        let offer = try await peerConnection.offer(for: offerConstraints)
        try await peerConnection.setLocalDescription(offer)
        await waitForIceGatheringComplete(peerConnection)

        guard let localDescription = peerConnection.localDescription else {
            throw MirrorSessionError.failedToCreatePeerConnection
        }
        let wireOffer = WireSessionDescription(type: "offer", sdp: localDescription.sdp)
        return String(decoding: try JSONEncoder().encode(wireOffer), as: UTF8.self)
    }

    // addTransceiver(with:) alone (no stream id) produces "a=msid:- <id>" —
    // stream id "-", RFC 8830's marker for "no associated MediaStream".
    // streamIds restores a real one. See the call sites for why video and
    // audio deliberately get *different* stream ids rather than sharing one.
    @discardableResult
    private func addSendOnlyTrack(
        _ track: RTCMediaStreamTrack, streamId: String, to peerConnection: RTCPeerConnection
    ) -> RTCRtpTransceiver? {
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = [streamId]
        if let transceiver = peerConnection.addTransceiver(with: track, init: transceiverInit) {
            return transceiver
        }
        _ = peerConnection.add(track, streamIds: [streamId])
        return nil
    }

    // Forwards to the running capture session; a no-op if nothing's
    // mirroring, since a swap can race stop() the same way
    // ScreenCaptureSession's own guard does.
    public func updateFilter(_ filter: SCContentFilter) async throws {
        try await captureSession?.updateFilter(filter)
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
#endif
