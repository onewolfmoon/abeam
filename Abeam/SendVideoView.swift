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
            #if os(iOS)
                Text("Sending video from an app")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(
                    "1. Tap \(Image(systemName: "square.and.arrow.up")) on an episode"
                ).frame(maxWidth: .infinity, alignment: .leading)

                Text("2. Choose \(Image("AppIcon-iOS-Default-20")) Abeam")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            #endif

            ControlGroup {
                Button("Display on") {
                    Task { await sendDisplayOn() }
                }

                Button("Display off") {
                    Task { await sendDisplayOff() }
                }
            }.controlSize(.extraLarge)

            videoLinkField

            GlassEffectContainer {
                HStack {
                    Button {
                        Task { await sendControl(.seekBack) }
                    } label: {
                        Label(
                            "Seek Back 5 Seconds",
                            systemImage: "gobackward.5"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 24))
                        .frame(width: 48, height: 48)
                    }

                    Button {
                        Task { await sendControl(.playPause) }
                    } label: {
                        Label("Play/Pause", systemImage: "playpause.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 32))
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        Task { await sendControl(.seekForward) }
                    } label: {
                        Label(
                            "Seek Forward 5 Seconds",
                            systemImage: "goforward.5"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 24))
                        .frame(width: 48, height: 48)
                    }

                    Button {
                        Task { await sendStop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 24))
                            .frame(width: 48, height: 48)
                    }
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
            }

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

#Preview {
    SendVideoView(model: AppModel())
}
