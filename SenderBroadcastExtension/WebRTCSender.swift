import Foundation
import CoreMedia
import WebRTC
import SenderKit
import OSLog

// Owns a single video-only RTCPeerConnection and drives the same
// offer/wait-for-ICE-gathering/POST/answer handshake that the macOS Sender's
// JS does against Receiver's ControlServer (see vga/Sources/SignalingCore/Resources/sender.html
// and vga/Sources/Receiver/ControlServer.swift): no STUN/TURN, no trickle ICE.
//
// Deliberately not actor-isolated: ReplayKit calls
// processSampleBuffer/deliver(pixelBuffer:presentationTimeStamp:) at frame
// rate from its own queue, and hopping to the main actor for every frame
// would be wasteful. `start`/`stop` are only ever called sequentially by
// SampleHandler (start completes, or fails, before frames start arriving;
// stop happens once broadcastFinished fires), so there's no concurrent
// access to the peer connection itself despite the lack of actor protection.
nonisolated final class WebRTCSender: NSObject {
    enum SenderError: Error, LocalizedError {
        case connectionSetupFailed
        case missingLocalDescription

        var errorDescription: String? {
            switch self {
            case .connectionSetupFailed: return "failed to create the peer connection"
            case .missingLocalDescription: return "no local SDP after offer/gathering"
            }
        }
    }

    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var deliveredFrameCount = 0

    func start(receiverAddress: String) async throws {
        Logger.webRTC.log("start: receiverAddress='\(receiverAddress, privacy: .public)'")
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            Logger.webRTC.error("start: factory.peerConnection returned nil")
            throw SenderError.connectionSetupFailed
        }
        self.peerConnection = peerConnection

        let videoSource = factory.videoSource(forScreenCast: true)
        // Cap the encoded resolution/frame rate; RTCVideoSource scales, crops
        // and drops frames from whatever raw size ReplayKit delivers to fit
        // this, which keeps bandwidth/CPU (and the extension's ~50MB memory
        // budget) reasonable over a LAN link.
        videoSource.adaptOutputFormat(toWidth: 1170, height: 2532, fps: 20)
        self.videoSource = videoSource
        let capturer = RTCVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        peerConnection.add(videoTrack, streamIds: ["stream0"])

        Logger.webRTC.log("start: creating offer")
        let offer = try await peerConnection.offer(for: constraints)
        try await peerConnection.setLocalDescription(offer)
        Logger.webRTC.log("start: local description set, waiting for ICE gathering")
        await waitForIceGatheringComplete(peerConnection)
        Logger.webRTC.log("start: ICE gathering finished with state=\(peerConnection.iceGatheringState.rawValue)")

        guard let localDescription = peerConnection.localDescription else {
            Logger.webRTC.error("start: no localDescription after gathering")
            throw SenderError.missingLocalDescription
        }
        let offerMessage = SessionDescriptionMessage(
            type: RTCSessionDescription.string(for: localDescription.type),
            sdp: localDescription.sdp
        )
        Logger.webRTC.log("start: POSTing offer to receiver")
        do {
            let answerMessage = try await ControlClient.sendOffer(offerMessage, toReceiverAt: receiverAddress)
            Logger.webRTC.log("start: got answer from receiver, applying it")
            let answer = RTCSessionDescription(
                type: RTCSessionDescription.type(for: answerMessage.type),
                sdp: answerMessage.sdp
            )
            try await peerConnection.setRemoteDescription(answer)
            Logger.webRTC.log("start: remote description applied, handshake complete")
        } catch {
            Logger.webRTC.error("start: sendOffer failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func stop() {
        Logger.webRTC.log("stop: closing peer connection (delivered \(self.deliveredFrameCount) frames total)")
        peerConnection?.close()
        peerConnection = nil
        videoSource = nil
        videoCapturer = nil
    }

    func deliver(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let capturer = videoCapturer, let videoSource else { return }
        deliveredFrameCount += 1
        if deliveredFrameCount == 1 || deliveredFrameCount % 100 == 0 {
            Logger.webRTC.log("deliver: frame #\(self.deliveredFrameCount)")
        }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(presentationTimeStamp) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timeStampNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    // Mirrors waitForIceGatheringComplete in vga/Sources/SignalingCore/Resources/common.js:
    // Receiver only responds once its own answer's ICE gathering is done, so
    // the offer we send must likewise already have every host candidate
    // embedded (no trickle ICE on either side).
    private func waitForIceGatheringComplete(_ peerConnection: RTCPeerConnection) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while peerConnection.iceGatheringState != .complete, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if peerConnection.iceGatheringState != .complete {
            Logger.webRTC.error("waitForIceGatheringComplete: timed out, state=\(peerConnection.iceGatheringState.rawValue)")
        }
    }
}

extension WebRTCSender: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Logger.webRTC.log("delegate: signalingState=\(stateChanged.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Logger.webRTC.log("delegate: iceConnectionState=\(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Logger.webRTC.log("delegate: iceGatheringState=\(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Logger.webRTC.log("delegate: generated ICE candidate: \(candidate.sdp, privacy: .public)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Logger.webRTC.log("delegate: connectionState=\(newState.rawValue)")
    }
}

extension Logger {
    static let webRTC = Logger(subsystem: "com.wesleymoy.VGASender", category: "WebRTCSender")
}
