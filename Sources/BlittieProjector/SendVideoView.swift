import SwiftUI
import ReceiverProtocol

struct SendVideoView: View {
    @Bindable var model: AppModel
    @State private var urlText = ""
    @State private var isSending = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Video URL")
                    .font(.body.weight(.semibold))
                HStack {
                    TextField("https://example.com/video.mp4", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))

            VStack(spacing: 14) {
                Text("Playback Controls")
                    .font(.subheadline.bold())
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                HStack(spacing: 26) {
                    controlButton(systemImage: "gobackward.5", label: "Seek Back 5 Seconds") {
                        Task { await sendControl(.seekBack) }
                    }
                    Button {
                        Task { await sendControl(.playPause) }
                    } label: {
                        Label("Play/Pause", systemImage: "playpause.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18))
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    controlButton(systemImage: "goforward.5", label: "Seek Forward 5 Seconds") {
                        Task { await sendControl(.seekForward) }
                    }
                    controlButton(systemImage: "stop.fill", label: "Stop") {
                        Task { await sendStop() }
                    }
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 480)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func controlButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 16))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
    }

    private func send() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        isSending = true
        statusMessage = "sending to receiver…"
        Task {
            do {
                try await model.sendYouTube(url: url)
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
