import SwiftUI
@preconcurrency import WebRTC

// NSViewRepresentable wrapping WebRTC's own Metal-backed remote-video view
// — the native analog of receiver.html's <video id="remoteVideo">. No
// WebView anywhere in this path.
struct NativeMirrorView: NSViewRepresentable {
    let session: NativeMirrorSession

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView()
        if let track = session.videoTrack {
            track.add(view)
            context.coordinator.didAttach = true
        }
        return view
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        // videoTrack can, in principle, become available slightly after
        // makeNSView already ran (see NativeMirrorSession.videoTrack's doc
        // comment) — attach it here too so a late-arriving track still gets
        // rendered rather than leaving the view permanently blank.
        guard !context.coordinator.didAttach, let track = session.videoTrack else { return }
        track.add(nsView)
        context.coordinator.didAttach = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var didAttach = false
    }
}
