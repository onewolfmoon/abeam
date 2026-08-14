import WebRTC

// Scaffold only — ScreenCaptureKit capture + WebRTC peer connection bridging
// lands here in a later phase. This proves the WebRTC binary dependency
// resolves and links on both platforms.
public enum MirrorKit {
    public static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory()
    }
}
