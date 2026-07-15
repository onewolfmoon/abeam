import SwiftUI

struct SendVideoView: View {
    @Bindable var model: AppModel
    @State private var urlText = ""
    @State private var isSending = false
    // Optimistic only: the Receiver doesn't report playback state back, so
    // this just reflects the last control we sent, the same as the
    // web Sender it replaces.
    @State private var isPlaying = true
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Video URL")
                    .font(.system(size: 13, weight: .semibold))
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
                Text("PLAYBACK CONTROLS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 26) {
                    controlButton(systemImage: "gobackward.5") {
                        Task { await sendControl("seek-back") }
                    }
                    Button {
                        Task { await togglePlayPause() }
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    controlButton(systemImage: "goforward.5") {
                        Task { await sendControl("seek-forward") }
                    }
                    controlButton(systemImage: "stop.fill") {
                        Task { await sendControl("stop") }
                        isPlaying = true
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

    private func controlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
    }

    private func send() {
        guard let address = model.receiverAddress else { return }
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        isSending = true
        statusMessage = "sending to receiver…"
        Task {
            do {
                try await ReceiverClient.sendVideo(url: url, to: address)
                statusMessage = "receiver is playing the video"
                isPlaying = true
                urlText = ""
            } catch {
                statusMessage = "error: \(error.localizedDescription)"
            }
            isSending = false
        }
    }

    private func togglePlayPause() async {
        if await sendControl("play-pause") {
            isPlaying.toggle()
        }
    }

    @discardableResult
    private func sendControl(_ path: String) async -> Bool {
        guard let address = model.receiverAddress else { return false }
        do {
            let handled = try await ReceiverClient.control(path, to: address)
            if !handled {
                statusMessage = "nothing is playing right now"
            }
            return handled
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
            return false
        }
    }
}
