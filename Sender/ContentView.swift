import SwiftUI
import SenderKit

struct ContentView: View {
    // Must match SenderBroadcastExtension's PRODUCT_BUNDLE_IDENTIFIER in project.yml.
    private let broadcastExtensionBundleID = "com.wesleymoy.VGASender.BroadcastExtension"

    @State private var receiverAddress: String = ReceiverAddressStore.address
    @State private var youtubeURL: String = ""
    @State private var youtubeStatus: String = "idle"
    @State private var isSendingYouTube = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Deliberately outside the Form below: RPSystemBroadcastPickerView's
                // internal button doesn't reliably receive taps when placed inside a
                // Form/List row, since the row's own selection gesture recognizer can
                // swallow the touch first.
                screencastSection
                    .padding()

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
            }
            .navigationTitle("VGA Sender")
        }
    }

    private var screencastSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live screencast")
                .font(.headline)
            HStack {
                BroadcastPickerView(preferredExtensionBundleID: broadcastExtensionBundleID)
                    .frame(width: 50, height: 50)
                Text("Tap to start mirroring your whole screen to the Receiver.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
