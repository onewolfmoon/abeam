#if canImport(ScreenCaptureKit)
    import SwiftUI
    @preconcurrency import WebRTC

    /// A live preview of the local video track being mirrored, shown while
    /// screen mirroring is active. This renders the exact frames being sent
    /// to the receiver, using the same RTCVideoTrack the peer connection
    /// encodes from.
    ///
    /// `epoch` should change (e.g. the mirroring session's start time) each
    /// time a new mirroring session begins on `session`, so the view knows to
    /// fetch and attach the new session's video track.
    @available(iOS 27, *)
    public struct MirrorPreviewView: View {
        private let session: WebRTCMirrorSession
        private let epoch: Date
        @State private var videoTrack: RTCVideoTrack?

        public init(session: WebRTCMirrorSession, epoch: Date) {
            self.session = session
            self.epoch = epoch
        }

        public var body: some View {
            VideoTrackView(videoTrack: videoTrack)
                .task(id: epoch) {
                    videoTrack = session.localVideoTrack()
                }
        }
    }

    #if os(iOS)
        @available(iOS 27, *)
        private struct VideoTrackView: UIViewRepresentable {
            let videoTrack: RTCVideoTrack?

            func makeUIView(context: Context) -> RTCMTLVideoView {
                let view = RTCMTLVideoView()
                view.videoContentMode = .scaleAspectFit
                attach(to: view, context: context)
                return view
            }

            func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
                attach(to: uiView, context: context)
            }

            func makeCoordinator() -> Coordinator { Coordinator() }

            private func attach(to view: RTCMTLVideoView, context: Context) {
                guard context.coordinator.attachedTrack !== videoTrack else { return }
                context.coordinator.attachedTrack?.remove(view)
                videoTrack?.add(view)
                context.coordinator.attachedTrack = videoTrack
            }

            final class Coordinator {
                var attachedTrack: RTCVideoTrack?
            }
        }
    #elseif os(macOS)
        @available(iOS 27, *)
        private struct VideoTrackView: NSViewRepresentable {
            let videoTrack: RTCVideoTrack?

            func makeNSView(context: Context) -> RTCMTLNSVideoView {
                let view = RTCMTLNSVideoView()
                attach(to: view, context: context)
                return view
            }

            func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
                attach(to: nsView, context: context)
            }

            func makeCoordinator() -> Coordinator { Coordinator() }

            private func attach(to view: RTCMTLNSVideoView, context: Context) {
                guard context.coordinator.attachedTrack !== videoTrack else { return }
                context.coordinator.attachedTrack?.remove(view)
                videoTrack?.add(view)
                context.coordinator.attachedTrack = videoTrack
            }

            final class Coordinator {
                var attachedTrack: RTCVideoTrack?
            }
        }
    #endif
#endif
