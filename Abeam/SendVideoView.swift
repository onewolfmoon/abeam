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
            displayControls
            videoLinkField
            playbackControls

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture { isURLFieldFocused = false }

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
    private var displayControls: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer {
                displayControlsButtonRow
            }
        } else {
            displayControlsButtonRow
        }
    }

    @ViewBuilder
    private var displayControlsButtonRow: some View {
        HStack {
            controlButton(systemImage: "sun.max", label: "Turn Display On") {
                Task { await sendDisplayOn() }
            }
            controlButton(systemImage: "moon", label: "Turn Display Off") {
                Task { await sendDisplayOff() }
            }
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
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
        let label = Label(label, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 24))
            .frame(width: 48, height: 48)

        if #available(iOS 26.0, macOS 26.0, *) {
            Button(action: action) { label }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func primaryControlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let label = Label(label, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 32))
            .frame(width: 64, height: 64)

        if #available(iOS 26.0, macOS 26.0, *) {
            Button(action: action) { label }
                .buttonBorderShape(.circle)
                .buttonStyle(.glassProminent)
        } else {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
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

    private func sendDisplayOn() async {
        isURLFieldFocused = false
        do {
            try await model.sendDisplayOn()
            statusMessage = "turning the display on…"
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
        }
    }

    private func sendDisplayOff() async {
        isURLFieldFocused = false
        do {
            try await model.sendDisplayOff()
            statusMessage = "turning the display off…"
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
        }
    }
}
