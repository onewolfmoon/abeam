#if canImport(ScreenCaptureKit)
    import CoreVideo
    import Foundation
    import ImageIO
    import MirrorKitAudioBridge
    @preconcurrency import ScreenCaptureKit
    @preconcurrency import WebRTC
    import CoreMedia

    public enum MirrorSessionError: Error, Sendable {
        case failedToCreatePeerConnection
        case notMirroring
    }

    /// The JSON payload format for the WebRTC SDP message.
    private struct WireSessionDescription: Codable {
        let type: String
        let sdp: String
    }

    /// A bridge from ScreenCaptureSession's frames into a WebRTC
    /// RTCPeerConnection.
    ///
    /// The WebRTC connection uses the WebSocket connection formed from Bounjour
    /// discovery for SDP exchange. No STUN/TURN/ICE servers are involved.
    /// Trickle ICE is not supported.
    ///
    /// This class is an actor because RTCPeerConnectionDelegate callbacks land
    /// on WebRTC's own signaling thread, not the caller's context.
    @available(iOS 27, *)
    public actor WebRTCMirrorSession: NSObject, RTCPeerConnectionDelegate {
        public enum ConnectionState: Sendable, Equatable {
            case new, connecting, connected, disconnected, failed, closed
            /// The shared window/display was closed, ending capture.
            case captureEnded
        }

        /// Which kind of content is being mirrored.
        public enum ContentOptimization: Sendable, Equatable {
            /// Keeps faces defined in moving video.
            case motion
            /// Keeps text legible at smaller sizes.
            case textAndImages

            fileprivate var forScreenCast: Bool {
                switch self {
                case .motion: return false
                case .textAndImages: return true
                }
            }
        }

        private let factory: RTCPeerConnectionFactory
        private let audioDevice: ScreenAudioDevice
        private var peerConnection: RTCPeerConnection?
        private var captureSession: ScreenCaptureSession?
        // Written once inside startMirroring() (actor-isolated) and read from
        // MirrorPreviewView only after that call has already returned to its
        // caller, so the write happens-before every read. nonisolated(unsafe)
        // avoids forcing that read to hop onto the actor merely to fetch a
        // reference that's already safely published by that happens-before
        // edge. Same rationale as NativeMirrorSession's ConnectionObserver.
        private nonisolated(unsafe) var videoTrack: RTCVideoTrack?
        private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
        private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

        override public init() {
            let audioDevice = ScreenAudioDevice()
            self.audioDevice = audioDevice
            // The default RTCDefaultVideoEncoderFactory has a limit of 720p.
            // HighLevelH264EncoderFactory raises the limit to 1080p.
            //
            // The default RTCAudioSession records microphone audio.
            // ScreenAudioDevice captures system output audio.
            self.factory = MirrorKitMakePeerConnectionFactory(
                HighLevelH264EncoderFactory(),
                RTCDefaultVideoDecoderFactory(),
                audioDevice
            )
            super.init()
        }

        /// Starts listening for connection state changes. This must be called
        /// before startMirroring().
        public func connectionStates() -> AsyncStream<ConnectionState> {
            AsyncStream { continuation in
                self.stateContinuation = continuation
            }
        }

        public func startMirroring(
            filter: SCContentFilter, contentOptimization: ContentOptimization
        ) async throws -> String {
            let config = RTCConfiguration()
            config.iceServers = []
            config.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [:], optionalConstraints: [:])

            // Turn off echo cancellation, automatic gain, noise suppression,
            // and high-pass filter. These are designed for microphone input and
            // are on by default in WebRTCVoiceEngine in the WebRTC library.
            //
            // These string keys are hardcoded here because the library doesn't
            // expose them. See CopyConstraintsIntoAudioOptions to see where
            // they're used.
            let audioConstraints = RTCMediaConstraints(
                mandatoryConstraints: [:],
                optionalConstraints: [
                    "googEchoCancellation": kRTCMediaConstraintsValueFalse,
                    "googAutoGainControl": kRTCMediaConstraintsValueFalse,
                    "googNoiseSuppression": kRTCMediaConstraintsValueFalse,
                    "googHighpassFilter": kRTCMediaConstraintsValueFalse,
                ])

            guard
                let peerConnection = factory.peerConnection(
                    with: config, constraints: constraints, delegate: self)
            else {
                throw MirrorSessionError.failedToCreatePeerConnection
            }
            self.peerConnection = peerConnection

            let videoSource = factory.videoSource(forScreenCast: contentOptimization.forScreenCast)
            let videoCapturer = RTCVideoCapturer(delegate: videoSource)
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            self.videoTrack = videoTrack

            addSendOnlyTrack(videoTrack, streamId: "mirror0", to: peerConnection)

            let audioSource = factory.audioSource(with: audioConstraints)
            let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
            // This stream ID matches the ID of the video track to engage
            // syncing between the two tracks.
            //
            // TODO: Change this back to `mirror0-audio` to desync if syncing
            // results in worse performance.
            let audioTransceiver = addSendOnlyTrack(
                audioTrack, streamId: "mirror0", to: peerConnection)

            // Prioritize audio on the connection because popcorn sucks.
            if let audioSender = audioTransceiver?.sender {
                let parameters = audioSender.parameters
                for encoding in parameters.encodings {
                    encoding.networkPriority = .high
                }
                audioSender.parameters = parameters
            }

            let audioDevice = self.audioDevice
            let captureSession = ScreenCaptureSession(
                onSampleBuffer: { sampleBuffer in
                    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
                    // TODO(#79 diagnostics): remove once frame rotation is confirmed working.
                    logFrameAttachmentsIfNeeded(sampleBuffer, pixelBuffer: pixelBuffer)
                    let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
                    // Do not use the system clock. It's not monotonic.
                    let frame = RTCVideoFrame(
                        buffer: rtcBuffer, rotation: rtcRotation(for: sampleBuffer),
                        timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
                    videoSource.capturer(videoCapturer, didCapture: frame)
                },
                onAudioSampleBuffer: { sampleBuffer in
                    audioDevice.deliverAudioSampleBuffer(sampleBuffer)
                },
                onStop: { [weak self] stoppedSession, _ in
                    Task { await self?.handleCaptureStopped(stoppedSession) }
                })
            self.captureSession = captureSession
            try await captureSession.start(filter: filter)

            let offerConstraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueFalse
                ],
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

        /// Adds a track with the given ID.
        ///
        /// addTransceiver(with:) on the peer connection doesn't set the stream
        /// ID, and that produces a stream with ID "-" meaning _no associated
        /// MediaStream_ (that is, "a=msid:- <id>"; see RFC 8830).
        @discardableResult
        private func addSendOnlyTrack(
            _ track: RTCMediaStreamTrack, streamId: String, to peerConnection: RTCPeerConnection
        ) -> RTCRtpTransceiver? {
            let transceiverInit = RTCRtpTransceiverInit()
            // There's one obvious reason and one subtle reason to set
            // `.sendOnly`:
            // 1. It's true.
            // 2. A default sendrecv transceiver needs setLocalDescription to
            // resolve *receive* parameters too, which means matching the
            // offered codec against what RTCDefaultVideoDecoderFactory can
            // decode. This results in an H.264 level mismatch.
            // setLocalDescription() then fails outright with "Failed to set
            // local video description recv parameters" before Abeam sends its
            // offer to Abaft yet.
            transceiverInit.direction = .sendOnly
            transceiverInit.streamIds = [streamId]
            if let transceiver = peerConnection.addTransceiver(with: track, init: transceiverInit) {
                return transceiver
            }
            _ = peerConnection.add(track, streamIds: [streamId])
            return nil
        }

        /// Forwards the new content to the running capture session.
        public func updateFilter(_ filter: SCContentFilter) async throws {
            try await captureSession?.updateFilter(filter)
        }

        /// The local video track being captured and sent to the receiver.
        /// For rendering a local preview of what's being mirrored.
        /// Populated once startMirroring() has succeeded.
        nonisolated func localVideoTrack() -> RTCVideoTrack? {
            videoTrack
        }

        public func applyAnswer(sdp: String) async throws {
            guard let peerConnection else { throw MirrorSessionError.notMirroring }
            let wireAnswer = try JSONDecoder().decode(
                WireSessionDescription.self, from: Data(sdp.utf8))
            try await peerConnection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: wireAnswer.sdp))
        }

        public func stop() async {
            peerConnection?.close()
            peerConnection = nil
            try? await captureSession?.stop()
            captureSession = nil
            videoTrack = nil
            stateContinuation?.finish()
        }

        /// Handles ScreenCaptureSession ending on its own, such as when
        /// the shared window is closed.
        ///
        /// This callback should be called after the capture session is stopped.
        private func handleCaptureStopped(_ session: ScreenCaptureSession) async {
            // Ignore stale callbacks from a session that's since been
            // replaced by a new startMirroring() call.
            guard let captureSession, captureSession === session else { return }
            self.captureSession = nil
            try? await session.stop()
            peerConnection?.close()
            peerConnection = nil
            videoTrack = nil
            publish(.captureEnded)
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

        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
        ) {}
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream
        ) {}
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream
        ) {}
        nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        }
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
        ) {}
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate
        ) {}
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
        ) {}
        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel
        ) {}

        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
        ) {
            guard newState == .complete else { return }
            Task { await self.resolveIceGathering() }
        }

        nonisolated public func peerConnection(
            _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
        ) {
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

    // TODO(#79 diagnostics): temporary, to find out what ScreenCaptureKit
    // actually attaches to iOS screen-capture sample buffers. Remove this and
    // its call site once rotation is confirmed working end to end.
    //
    // Only mutated from ScreenCaptureSession's single serial capture queue
    // (MirrorKit.ScreenCaptureSession), so this is safe despite not being
    // actor-isolated.
    private nonisolated(unsafe) var lastAttachmentsLogTime: CFAbsoluteTime = 0

    private func logFrameAttachmentsIfNeeded(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAttachmentsLogTime > 1 else { return }
        lastAttachmentsLogTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[AnyHashable: Any]],
            let attachments = attachmentsArray.first
        {
            print("MirrorKit[#79]: buffer=\(width)x\(height) attachments=\(attachments)")
        } else {
            print("MirrorKit[#79]: buffer=\(width)x\(height) attachments=<none>")
        }
    }

    /// Reads the current display rotation ScreenCaptureKit attached to the
    /// sample buffer and converts it to the equivalent RTCVideoRotation.
    ///
    /// On iOS, rotating the device rotates the captured content, but the
    /// pixel buffer itself keeps its original dimensions and orientation;
    /// SCStreamFrameInfo.videoOrientation is how ScreenCaptureKit reports
    /// the correction needed. Without applying it, Abaft never sees the
    /// frame rotate. macOS doesn't rotate, and the attachment doesn't exist
    /// before macOS/iOS 27, so ._0 is the correct fallback there.
    private func rtcRotation(for sampleBuffer: CMSampleBuffer) -> RTCVideoRotation {
        guard #available(macOS 27, iOS 27, *) else { return ._0 }
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let orientationRawValue = attachments[.videoOrientation] as? Int,
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(orientationRawValue))
        else {
            return ._0
        }
        switch orientation {
        case .up, .upMirrored: return ._0
        case .right, .rightMirrored: return ._90
        case .down, .downMirrored: return ._180
        case .left, .leftMirrored: return ._270
        @unknown default: return ._0
        }
    }
#endif
