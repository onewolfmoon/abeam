@preconcurrency import WebRTC

// RTCDefaultVideoEncoderFactory's H264 entries (via RTCVideoEncoderH264.
// supportedCodecs(), confirmed by querying it directly) hardcode
// profile-level-id with level_idc 0x1f (Level 3.1, macroblock cap 3600 —
// exactly 1280x720). Encoding above that resolution against a Level 3.1
// VTCompressionSession fails silently on every frame, no error surfaced
// anywhere. RTCVideoEncoderH264 itself doesn't hardcode the level though —
// it only lives in the RTCVideoCodecInfo passed to its public initializer —
// so this factory just supplies the same profile at a higher level instead
// of reimplementing any encoding logic.
final class HighLevelH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    // Level 4.0 (level_idc 0x28) caps at 8192 macroblocks; 1920x1080 needs
    // 8160. High profile only, matching RTCVideoEncoderH264's own default
    // preference order (High offered before Baseline).
    private static let codecs = [
        RTCVideoCodecInfo(name: "H264", parameters: [
            "profile-level-id": "640028",
            "level-asymmetry-allowed": "1",
            "packetization-mode": "1",
        ]),
    ]

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        RTCVideoEncoderH264(codecInfo: info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        Self.codecs
    }
}
