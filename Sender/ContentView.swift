import SwiftUI
import SenderKit

struct ContentView: View {
    @State private var receiverAddress: String = ReceiverAddressStore.address
    @State private var youtubeURL: String = ""
    @State private var youtubeStatus: String = "idle"
    @State private var isSendingYouTube = false
    @State private var controlStatus: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Receiver address") {
                    TextField("e.g. 192.168.1.42:8787", text: $receiverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: receiverAddress) { _, newValue in
                            ReceiverAddressStore.address = newValue
                        }
                }

                Section("Play a YouTube video") {
                    TextField("https://www.youtube.com/watch?v=...", text: $youtubeURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        sendYouTube()
                    } label: {
                        if isSendingYouTube {
                            ProgressView()
                        } else {
                            Text("Send to Receiver")
                        }
                    }
                    .disabled(isSendingYouTube || youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(youtubeStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Playback controls") {
                    HStack {
                        Spacer()
                        Button {
                            sendControl(.seekBack)
                        } label: {
                            Label("Skip back 5s", systemImage: "gobackward.5")
                                .labelStyle(.iconOnly)
                        }
                        Spacer()
                        Button {
                            sendControl(.playPause)
                        } label: {
                            Label("Play/Pause", systemImage: "playpause.fill")
                                .labelStyle(.iconOnly)
                        }
                        Spacer()
                        Button {
                            sendControl(.seekForward)
                        } label: {
                            Label("Skip forward 5s", systemImage: "goforward.5")
                                .labelStyle(.iconOnly)
                        }
                        Spacer()
                    }
                    .font(.title2)
                    .disabled(receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !controlStatus.isEmpty {
                        Text(controlStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("VGA Sender")
        }
    }

    private func sendYouTube() {
        guard !receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            youtubeStatus = "enter the receiver's address first"
            return
        }
        isSendingYouTube = true
        youtubeStatus = "sending youtube url to receiver..."
        Task {
            defer { isSendingYouTube = false }
            do {
                try await ControlClient.sendYouTubeURL(youtubeURL, toReceiverAt: receiverAddress)
                youtubeStatus = "receiver is playing the video"
            } catch {
                youtubeStatus = "error: \(error.localizedDescription)"
            }
        }
    }

    private func sendControl(_ control: ControlClient.PlaybackControl) {
        guard !receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controlStatus = "enter the receiver's address first"
            return
        }
        Task {
            do {
                try await ControlClient.sendControl(control, toReceiverAt: receiverAddress)
                controlStatus = ""
            } catch {
                controlStatus = "error: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    ContentView()
}
