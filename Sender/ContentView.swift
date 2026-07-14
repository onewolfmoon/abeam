import SwiftUI
import SenderKit

struct ContentView: View {
    @State private var receiverAddress: String = ReceiverAddressStore.address
    @State private var youtubeURL: String = ""
    @State private var youtubeStatus: String = "idle"
    @State private var isSendingYouTube = false

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
}

#Preview {
    ContentView()
}
