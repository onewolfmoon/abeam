import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import WebRTC
import CoreMedia
import CoreVideo

public enum MirrorSessionError: Error, Sendable {
    case failedToCreatePeerConnection
    case notMirroring
}

// Diagnostic-only: no frames were visible in Blittie Screen's <video>
// element despite the peer connection reaching "connected" — need to know
// whether the break is upstream (no frames reaching RTCVideoSource at all)
// or downstream (frames sent but never decoded/rendered). Thread-safe
// because ScreenCaptureSession's onSampleBuffer always fires serially on
// its own capture queue, but the closure crosses into a @Sendable context.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
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
public actor WebRTCMirrorSession: NSObject, RTCPeerConnectionDelegate {
    public enum ConnectionState: Sendable, Equatable {
        case new, connecting, connected, disconnected, failed, closed
    }

    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var captureSession: ScreenCaptureSession?
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var statsTask: Task<Void, Never>?

    override public init() {
        super.init()
        // Surfaces libwebrtc's own internal logging (ICE/DTLS/encoder
        // messages it normally keeps silent) to the same stderr stream as
        // our own [WebRTCMirrorSession] logs.
        RTCSetMinDebugLogLevel(.info)
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
        startLoggingStats(peerConnection)

        let videoSource = factory.videoSource(forScreenCast: true)
        let videoCapturer = RTCVideoCapturer(delegate: videoSource)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        _ = peerConnection.add(videoTrack, streamIds: ["mirror0"])

        let frameCounter = FrameCounter()
        let captureSession = ScreenCaptureSession(onSampleBuffer: { sampleBuffer in
            guard let pixelBuffer = sampleBuffer.imageBuffer else {
                Self.log("onSampleBuffer fired with no imageBuffer")
                return
            }
            let count = frameCounter.increment()
            if count == 1 || count % 60 == 0 {
                let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
                Self.log("captured frame #\(count): \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) format=\(format)")
            }
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
        Self.log("offer ready, iceGatheringState=\(peerConnection.iceGatheringState.rawValue)")
        Self.log(localDescription.sdp)
        let wireOffer = WireSessionDescription(type: "offer", sdp: localDescription.sdp)
        return String(decoding: try JSONEncoder().encode(wireOffer), as: UTF8.self)
    }

    public func applyAnswer(sdp: String) async throws {
        guard let peerConnection else { throw MirrorSessionError.notMirroring }
        let wireAnswer = try JSONDecoder().decode(WireSessionDescription.self, from: Data(sdp.utf8))
        Self.log("applying answer")
        Self.log(wireAnswer.sdp)
        try await peerConnection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: wireAnswer.sdp))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[WebRTCMirrorSession] \(message)\n".utf8))
    }

    public func stop() async {
        statsTask?.cancel()
        statsTask = nil
        peerConnection?.close()
        peerConnection = nil
        try? await captureSession?.stop()
        captureSession = nil
        stateContinuation?.finish()
    }

    // Diagnostic-only: frames reach videoSource.capturer(_:didCapture:)
    // continuously (confirmed by the frame-count logging above) and ICE
    // reaches connected/completed, but Blittie Screen's <video> never
    // starts playing. Periodic outbound-rtp stats says definitively
    // whether the encoder is actually producing/sending anything, which
    // the delegate callbacks alone can't show.
    private func startLoggingStats(_ peerConnection: RTCPeerConnection) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.logOutboundStats(peerConnection)
            }
        }
    }

    private func logOutboundStats(_ peerConnection: RTCPeerConnection) async {
        let report = await peerConnection.statistics()
        for stat in report.statistics.values where stat.type == "outbound-rtp" {
            Self.log("outbound-rtp: \(stat.values)")
        }
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

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Self.log("signalingState -> \(stateChanged.rawValue)")
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Self.log("iceConnectionState -> \(newState.rawValue)")
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Self.log("generated local candidate: \(candidate.sdp)")
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Self.log("iceGatheringState -> \(newState.rawValue)")
        guard newState == .complete else { return }
        Task { await self.resolveIceGathering() }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Self.log("connectionState -> \(newState.rawValue)")
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
