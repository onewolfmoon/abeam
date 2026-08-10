@preconcurrency import ScreenCaptureKit
import CoreMedia

// Wrapper around SCStream: starts a video+audio capture for a given filter
// and forwards each sample buffer to onSampleBuffer/onAudioSampleBuffer,
// called directly from the capture callback — deliberately not routed
// through the actor, since hopping every frame through Task/actor isolation
// at 30-60fps (or every ~10-20ms audio chunk) would add needless latency to
// real-time media.
//
// An actor for the same reason as ScreenPicker: SCStreamOutput's callback
// fires on `queue`, not the caller's context.
//
// iOS 27 minimum: SCStream itself isn't available on iOS before then (see
// MirrorKit's Package.swift comment). macOS is unrestricted here since its
// floor (15) already clears ScreenCaptureKit's 12.3 requirement.
@available(iOS 27, *)
public actor ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "MirrorKit.ScreenCaptureSession")
    // Separate from `queue`: video frame handling (RTCVideoFrame construction,
    // handing off to the encoder) occasionally takes long enough that, on a
    // shared queue, audio buffers queue up behind it and then get delivered
    // to WebRTC in a burst once it frees up. WebRTC still encodes/sends that
    // audio correctly, but it arrives at the Receiver bunched up after a gap
    // — which is exactly what triggers a jitter buffer's catch-up
    // acceleration (silence, then a sped-up/fuzzy burst, repeating). Audio's
    // own queue means a slow video frame can never delay it.
    // .userInteractive: at the default QoS this queue would get, it can be
    // starved of CPU time by video capture/encoding under load the same as
    // any other best-effort work; CoreAudio's own render threads run at this
    // same elevated class for the same real-time-audio reason.
    private let audioQueue = DispatchQueue(label: "MirrorKit.ScreenCaptureSession.audio", qos: .userInteractive)
    private let onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    private let onAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    public init(
        onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil,
        onAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil
    ) {
        self.onSampleBuffer = onSampleBuffer
        self.onAudioSampleBuffer = onAudioSampleBuffer
        super.init()
    }

    public func start(filter: SCContentFilter, width: Int = 1920, height: Int = 1080) async throws {
        let config = SCStreamConfiguration()
        #if os(macOS)
        // macOS defaults to a fixed 1920x1080 output regardless of the
        // captured content's actual size; iOS/tvOS already default to the
        // content's native resolution and don't expose this property.
        config.width = width
        config.height = height
        #endif
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

    // Swaps what's being captured on the running stream in place — same
    // SCStream, same SCStreamOutput callback, just different frame content
    // from here on. No-op if the stream isn't running (e.g. a filter
    // update races a stop()).
    //
    // updateContentFilter is macOS/Mac Catalyst-only (SCStream has no
    // equivalent on iOS/visionOS), so this is a no-op there — consistent
    // with ScreenPicker never producing a swap event on those platforms
    // in the first place, since it can't offer allowsChangingSelectedContent
    // either.
    public func updateFilter(_ filter: SCContentFilter) async throws {
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

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: onSampleBuffer?(sampleBuffer)
        case .audio: onAudioSampleBuffer?(sampleBuffer)
        default: break
        }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
