@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

public struct CapturedFrameInfo: Sendable {
    public let width: Int
    public let height: Int
    public let timestamp: CMTime
}

// Wrapper around SCStream: starts a video-only capture for a given filter
// and pushes frame metadata through frames(), so callers can confirm frames
// are actually flowing (e.g. diagnostic UI). Real consumers that need pixel
// data (WebRTCMirrorSession) instead pass onSampleBuffer, called directly
// from the capture callback — deliberately not routed through the actor,
// since hopping every frame through Task/actor isolation at 30-60fps would
// add needless latency to the one path that actually matters for real-time
// video.
//
// An actor for the same reason as ScreenPicker: SCStreamOutput's callback
// fires on `queue`, not the caller's context.
public actor ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "MirrorKit.ScreenCaptureSession")
    private var continuation: AsyncStream<CapturedFrameInfo>.Continuation?
    private let onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    public init(onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    // Must be called before start(filter:) to observe frames from the very
    // first one; start(filter:) doesn't buffer frames for late subscribers.
    public func frames() -> AsyncStream<CapturedFrameInfo> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        #if os(macOS)
        // macOS defaults to a fixed 1920x1080 output regardless of the
        // captured content's actual size; iOS/tvOS already default to the
        // content's native resolution and don't expose this property.
        config.width = 1920
        config.height = 1080
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
        continuation?.finish()
    }

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onSampleBuffer?(sampleBuffer)
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let info = CapturedFrameInfo(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            timestamp: sampleBuffer.presentationTimeStamp
        )
        Task { await self.yield(info) }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await self.finish() }
    }

    private func yield(_ info: CapturedFrameInfo) {
        continuation?.yield(info)
    }

    private func finish() {
        continuation?.finish()
    }
}
