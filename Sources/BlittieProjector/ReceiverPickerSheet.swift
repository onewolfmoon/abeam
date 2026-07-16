import SwiftUI
import ReceiverProtocol

struct ReceiverPickerSheet: View {
    @Bindable var model: AppModel
    @State private var manualAddress = ""
    @State private var connectError: String?
    @State private var browser = ReceiverBrowser()
    @State private var discovered: [DiscoveredReceiver] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a Blittie Screen")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            List {
                Section("ON YOUR NETWORK") {
                    if discovered.isEmpty {
                        Text("No receivers found yet. Enter an address below to connect.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovered) { receiver in
                            Button {
                                select(receiver)
                            } label: {
                                Label(receiver.name, systemImage: "tv")
                            }
                        }
                    }
                }

                Section("OR ENTER AN ADDRESS") {
                    HStack {
                        TextField("e.g. 192.168.1.42 or living-room.local", text: $manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                            .buttonStyle(.borderedProminent)
                            .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let connectError {
                        Text(connectError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if case .manual = model.receiverEndpoint {
                manualAddress = model.receiverEndpoint?.displayName ?? ""
            }
        }
        .task {
            await browser.start()
            while !Task.isCancelled {
                discovered = await browser.results
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            let browser = browser
            Task { await browser.stop() }
        }
    }

    private func select(_ receiver: DiscoveredReceiver) {
        model.select(receiver)
        connectError = nil
        dismiss()
    }

    private func connect() {
        guard model.connect(to: manualAddress) else {
            connectError = "Enter an IP address or hostname."
            return
        }
        connectError = nil
        dismiss()
    }
}
