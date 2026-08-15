@preconcurrency import WebRTC

/// A factory for H.264 encoders that encode with the high profile at level 4.0.
/// This means that encoders have a macroblock cap of 8192, which is enough for
/// 1080p video.
///
/// Contrast with RTCDefaultVideoEncoderFactory, which is hardcoded to encode at
/// level 3.1. With its macroblock limit of 3600, it can only encode 720p video.
/// Attempting to use its encoders to mirror a display or window with a higher
/// resolution will result in Abaft receiving a completely black video in this
/// application.
final class HighLevelH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    static let maxMacroblocks = 8192

    // Hardcoded to high profile.
    private static let codecs = [
        RTCVideoCodecInfo(
            name: "H264",
            parameters: [
                "profile-level-id": "640028",
                "level-asymmetry-allowed": "1",
                "packetization-mode": "1",
            ]
        )
    ]

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        RTCVideoEncoderH264(codecInfo: info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        Self.codecs
    }
}
