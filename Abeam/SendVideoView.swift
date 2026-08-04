import ReceiverProtocol
import SwiftUI

struct SendVideoView: View {
    @Bindable var model: AppModel
    @State private var urlText = ""
    @State private var isSending = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                TextField("Video link", text: $urlText)
                    .frame(maxWidth: .infinity)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                Button(action: send) {
                    Label("Send", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSending
                )
                #if os(macOS)
                    .labelStyle(.titleOnly)
                #else
                    .labelStyle(.iconOnly)
                #endif
            }

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
        .padding()

        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16))
                    .frame(width: 44, height: 44)
            }
            .clipShape(Circle())
            .buttonStyle(.glass)
        } else {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16))
                    .frame(width: 44, height: 44)
            }
            .clipShape(Circle())
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func primaryControlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .frame(width: 56, height: 56)
            }
            .clipShape(Circle())
            .buttonStyle(.glassProminent)
        } else {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .frame(width: 56, height: 56)
            }
            .clipShape(Circle())
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
            } catch {
                statusMessage = "error: \(error.localizedDescription)"
            }
            isSending = false
        }
    }

    @discardableResult
    private func sendControl(_ control: ReceiverControl) async -> Bool {
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
