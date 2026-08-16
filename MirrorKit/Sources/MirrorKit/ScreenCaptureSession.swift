#if canImport(ScreenCaptureKit)
    @preconcurrency import ScreenCaptureKit
    import CoreMedia

    /// A wrapper around SCStream that starts a video+audio capture for a given
    /// filter and forwards each sample buffer to
    /// onSampleBuffer/onAudioSampleBuffer.
    ///
    /// This is deliberately not routed through the actor, since hopping every
    /// frame through Task/actor isolation at 30-60fps (or every ~10-20ms audio
    /// chunk) would add needless latency to real-time media.
    ///
    /// This class is an actor because SCStreamOutput's callback fires on
    /// `queue`, not the caller's context.
    @available(iOS 27, *)
    public actor ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
        private var stream: SCStream?
        private let queue = DispatchQueue(label: "MirrorKit.ScreenCaptureSession")
        // Core Audio supposedly operates at this level of QoS, so the queue for
        // audio samples does the same.
        private let audioQueue = DispatchQueue(
            label: "MirrorKit.ScreenCaptureSession.audio", qos: .userInteractive)
        private let onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
        private let onAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
        // Fires when the screen capture session naturally ends, such as
        // when the shared window is closed.
        private let onStop: (@Sendable (Error) -> Void)?

        public init(
            onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil,
            onAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil,
            onStop: (@Sendable (Error) -> Void)? = nil
        ) {
            self.onSampleBuffer = onSampleBuffer
            self.onAudioSampleBuffer = onAudioSampleBuffer
            self.onStop = onStop
            super.init()
        }

        public func start(filter: SCContentFilter) async throws {
            let config = SCStreamConfiguration()
            // Resize down if needed to fit under macroblock limit.
            let (width, height) = captureOutputSize(for: filter)
            config.width = width
            config.height = height
            // System/app audio alongside video. sampleRate/channelCount default
            // to 48000/2 already, matching ScreenAudioDevice's fixed output
            // format on the WebRTC side.
            config.capturesAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            self.stream = stream
            try await stream.startCapture()
        }

        /// Swaps what's being captured on the running stream. Noop if the
        /// stream isn't running.
        public func updateFilter(_ filter: SCContentFilter) async throws {
            // updateContentFilter is macOS-only.
            #if os(macOS)
                guard let stream else { return }
                try await stream.updateContentFilter(filter)
            #endif
        }

        public func stop() async throws {
            guard let stream else { return }
            self.stream = nil
            try await stream.stopCapture()
        }

        nonisolated public func stream(
            _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            switch type {
            case .screen: onSampleBuffer?(sampleBuffer)
            case .audio: onAudioSampleBuffer?(sampleBuffer)
            default: break
            }
        }

        nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStop?(error)
        }
    }

    /// Returns the scaled size of the video output if it would exceed the
    /// resolution that can be encoded by HighLevelH264EncoderFactory encoders.
    /// The incoming sizes are already in points, so this further downsizing is
    /// mostly for very large displays on macOS.
    ///
    /// Failing to stay under the macroblock limit results in a fully black
    /// screen on the Abaft screen.
    @available(iOS 27, *)
    private func captureOutputSize(for filter: SCContentFilter) -> (width: Int, height: Int) {
        let pointWidth = Double(filter.contentRect.width)
        let pointHeight = Double(filter.contentRect.height)

        for scale in [1.0, 0.5, 0.25] {
            let width = evenFloor(pointWidth * scale)
            let height = evenFloor(pointHeight * scale)
            if macroblockCount(width: width, height: height)
                <= HighLevelH264EncoderFactory.maxMacroblocks
            {
                return (width, height)
            }
        }
        // Too big, even at 0.25x.
        // TODO: Signal an error.
        return (evenFloor(pointWidth * 0.25), evenFloor(pointHeight * 0.25))
    }

    /// The number of 16x16 macroblocks needed to contain a video of the given
    /// dimensions.
    private func macroblockCount(width: Int, height: Int) -> Int {
        ((width + 15) / 16) * ((height + 15) / 16)
    }

    private func evenFloor(_ value: Double) -> Int {
        let n = Int(value)
        return n - (n % 2)
    }
#endif
