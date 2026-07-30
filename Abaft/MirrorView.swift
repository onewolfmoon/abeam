import SwiftUI
import MirrorKit

// Phase 2 spike: confirms ScreenCaptureKit frames actually arrive before any
// WebRTC bridging gets built on top. Not the real mirroring UI — that lands
// once MirrorKit grows a WebRTC peer connection and this view starts calling
// model.sendOffer(sdp:) the same way SendVideoView already talks to the
// receiver.
struct MirrorView: View {
    @Bindable var model: AppModel

    @State private var picker = ScreenPicker()
    @State private var session = ScreenCaptureSession()
    @State private var frameTask: Task<Void, Never>?
    @State private var isCapturing = false
    @State private var frameCount = 0
    @State private var lastFrameSize = "—"
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Screen Mirroring", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("Native WebRTC mirroring isn't wired up yet. This is a ScreenCaptureKit capture diagnostic.")
            }

            VStack(spacing: 10) {
                Text("Frames captured: \(frameCount)")
                Text("Last frame size: \(lastFrameSize)")
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
                Button(isCapturing ? "Stop Capture" : "Pick Content & Start Capture") {
                    Task { await toggleCapture() }
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.callout)
        }
        .padding()
        .onDisappear {
            frameTask?.cancel()
            if isCapturing {
                Task { try? await session.stop() }
            }
        }
    }

    private func toggleCapture() async {
        if isCapturing {
            await stopCapture()
        } else {
            await startCapture()
        }
    }

    private func startCapture() async {
        statusMessage = "waiting for picker…"
        do {
            let filter = try await picker.pickContent()
            frameCount = 0
            lastFrameSize = "—"
            frameTask = Task {
                for await info in await session.frames() {
                    frameCount += 1
                    lastFrameSize = "\(info.width)x\(info.height)"
                }
            }
            try await session.start(filter: filter)
            statusMessage = nil
            isCapturing = true
        } catch ScreenPickerError.cancelled {
            statusMessage = nil
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
        }
    }

    private func stopCapture() async {
        frameTask?.cancel()
        try? await session.stop()
        isCapturing = false
        statusMessage = nil
    }
}
