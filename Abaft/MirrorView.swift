import SwiftUI

// Placeholder for the native ScreenCaptureKit + WebRTC mirroring flow.
// Lands in a later phase: SCContentSharingPicker → SCStream frames → a
// custom RTCVideoSource → offer/answer over the same model.sendOffer(sdp:)
// this app already uses for the video-send path.
struct MirrorView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Screen Mirroring", systemImage: "rectangle.on.rectangle")
        } description: {
            Text("Native ScreenCaptureKit mirroring isn't wired up yet.")
        }
    }
}
