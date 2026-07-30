@preconcurrency import ScreenCaptureKit
import CoreMedia

// Wrapper around SCStream: starts a video-only capture for a given filter
// and forwards each sample buffer to onSampleBuffer, called directly from
// the capture callback — deliberately not routed through the actor, since
// hopping every frame through Task/actor isolation at 30-60fps would add
// needless latency to real-time video.
//
// An actor for the same reason as ScreenPicker: SCStreamOutput's callback
// fires on `queue`, not the caller's context.
public actor ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "MirrorKit.ScreenCaptureSession")
    private let onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    public init(onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil) {
        self.onSampleBuffer = onSampleBuffer
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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        try await stream.stopCapture()
    }

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onSampleBuffer?(sampleBuffer)
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
