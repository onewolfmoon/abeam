@preconcurrency import WebRTC

// RTCDefaultVideoDecoderFactory's H264 entries hardcode profile-level-id to
// 42e01f (Constrained Baseline) and 640c1f (Constrained High), both Level
// 3.1 — confirmed by grepping the WebRTC.framework binary for those two hex
// strings and finding no others. Abaft's HighLevelH264EncoderFactory (see
// that type in MirrorKit) instead offers plain High Profile at Level 4.0
// (profile-level-id 640028, needed for 1080p — Level 3.1's macroblock cap
// tops out at 1280x720) as its *only* codec, no VP8/VP9 fallback. Neither of
// the default factory's two entries matches 640028 (different profile, not
// just different level — Constrained High and High are distinct RTCH264Profile
// values), so an Abaft offer against a plain RTCDefaultVideoDecoderFactory
// negotiates zero common codecs: WebRTC answers with the sole m=video line
// rejected, no transport ever gets created for it, and
// NativeMirrorSession.waitForIceGatheringComplete()'s poll loop spins
// forever waiting for a gathering-state transition that can never come —
// Abaft hangs before ever showing a window, and Abaft hangs awaiting the
// answer that never arrives.
//
// This factory adds a decoder for 640028 on top of (not instead of) the
// stock decoder factory's own list, so senders using the default profiles
// (old BlittieProjector's WKWebView-hosted RTCPeerConnection, still on
// RTCDefaultVideoEncoderFactory equivalents) keep working exactly as before.
final class HighLevelH264DecoderFactory: NSObject, RTCVideoDecoderFactory {
    private static let highProfileCodec = RTCVideoCodecInfo(name: "H264", parameters: [
        "profile-level-id": "640028",
        "level-asymmetry-allowed": "1",
        "packetization-mode": "1",
    ])

    private let defaultFactory = RTCDefaultVideoDecoderFactory()

    // RTCVideoDecoderH264 has no codecInfo-taking initializer (unlike its
    // encoder counterpart) — decoding isn't profile/level-configured the way
    // VTCompressionSession encoding is, so any H264 payload, regardless of
    // which profile-level-id negotiated it, decodes the same way.
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        if info.name == kRTCVideoCodecH264Name {
            return RTCVideoDecoderH264()
        }
        return defaultFactory.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        [Self.highProfileCodec] + defaultFactory.supportedCodecs()
    }
}
