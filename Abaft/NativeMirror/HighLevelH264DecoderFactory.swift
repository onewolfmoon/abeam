@preconcurrency import WebRTC

/// A factory that provides H.264 decoders for the "high" profile up to level
/// 4.0. This provides support for up to 1080p video.
///
/// Contrast with RTCDefaultVideoDecoderFactory, which only supports up to 720p
/// video. Trying to use RTCDefaultVideoDecoderFactory with 1080p video that
/// Abeam sends will result in a failure in WebRTC ICE negotiation, and Abaft
/// will hang while waiting for ICE to complete.
final class HighLevelH264DecoderFactory: NSObject, RTCVideoDecoderFactory {
    private static let highProfileCodec = RTCVideoCodecInfo(
        name: "H264",
        parameters: [
            "profile-level-id": "640028",
            "level-asymmetry-allowed": "1",
            "packetization-mode": "1",
        ]
    )

    private let defaultFactory = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        // RTCVideoDecoderH264 accepts any H264 payload, regardless of profile
        // and level.
        if info.name == kRTCVideoCodecH264Name {
            return RTCVideoDecoderH264()
        }
        return defaultFactory.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        [Self.highProfileCodec] + defaultFactory.supportedCodecs()
    }
}
