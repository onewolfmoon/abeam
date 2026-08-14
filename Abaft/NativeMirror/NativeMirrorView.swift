import SwiftUI
@preconcurrency import WebRTC

// WebRTC remote display as a SwiftUI View.
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
        // If the video track becomes available late, attaching it here makes it
        // more likely to appear rather than having the view stay blank.
        guard !context.coordinator.didAttach, let track = session.videoTrack
        else { return }
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
