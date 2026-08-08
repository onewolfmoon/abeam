import WebRTC

// Scaffold only — ScreenCaptureKit capture + WebRTC peer connection bridging
// lands here in a later phase. This proves the WebRTC binary dependency
// resolves and links on both platforms.
public enum MirrorKit {
    public static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory()
    }

    // Lets callers decide whether to offer screen mirroring at all, without
    // needing to know ScreenPicker/ScreenCaptureSession/WebRTCMirrorSession's
    // own iOS 27 floor themselves. `#available` is unconditionally true on
    // macOS (and any platform not named), so this is only ever false on
    // iOS/iPadOS below 27.
    public static var isScreenMirroringSupported: Bool {
        if #available(iOS 27, *) {
            true
        } else {
            false
        }
    }
}
