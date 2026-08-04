import ReceiverProtocol
import SwiftUI

struct SendVideoView: View {
    @Bindable var model: AppModel
    @State private var urlText = ""
    @State private var isSending = false
    @State private var statusMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            videoLinkField
            playbackControls
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture { isURLFieldFocused = false }

        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var videoLinkField: some View {
        #if os(macOS)
            HStack {
                TextField("Video link", text: $urlText)
                    .frame(maxWidth: .infinity)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSending
                )
                .labelStyle(.titleOnly)
            }
        #else
            TextField("Video link", text: $urlText)
                .frame(maxWidth: .infinity)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
        #endif
    }

    @ViewBuilder
    private var playbackControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                playbackControlsButtonRow
            }
        } else {
            playbackControlsButtonRow
        }
    }

    @ViewBuilder
    private var playbackControlsButtonRow: some View {
        HStack {
            controlButton(
                systemImage: "gobackward.5",
                label: "Seek Back 5 Seconds"
            ) {
                Task { await sendControl(.seekBack) }
            }
            primaryControlButton(
                systemImage: "playpause.fill",
                label: "Play/Pause"
            ) {
                Task { await sendControl(.playPause) }
            }
            controlButton(
                systemImage: "goforward.5",
                label: "Seek Forward 5 Seconds"
            ) {
                Task { await sendControl(.seekForward) }
            }
            controlButton(systemImage: "stop.fill", label: "Stop") {
                Task { await sendStop() }
            }
        }
    }

    @ViewBuilder
    private func controlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 24))
                .padding(8)
        }
        .buttonBorderShape(.circle)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func primaryControlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 32))
                .padding(16)
        }
        .buttonBorderShape(.circle)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func send() {
        let payload = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }

        isSending = true
        statusMessage = "sending to receiver…"
        Task {
            do {
                try await model.sendVideo(payload: payload)
                statusMessage = "receiver is playing the video"
                urlText = ""
                isURLFieldFocused = false
            } catch {
                statusMessage = "error: \(error.localizedDescription)"
            }
            isSending = false
        }
    }

    @discardableResult
    private func sendControl(_ control: ReceiverControl) async -> Bool {
        isURLFieldFocused = false
        do {
            let handled = try await model.sendControl(control)
            if !handled {
                statusMessage = "nothing is playing right now"
            }
            return handled
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
            return false
        }
    }

    private func sendStop() async {
        isURLFieldFocused = false
        do {
            let handled = try await model.sendStop()
            if !handled {
                statusMessage = "nothing is playing right now"
            }
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
        }
    }
}
