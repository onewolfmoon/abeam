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
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("On Your Network")
                    if discovered.isEmpty {
                        Text("No receivers found yet. Enter an address below to connect.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovered) { receiver in
                            Button {
                                select(receiver)
                            } label: {
                                HStack {
                                    Image(systemName: "tv")
                                    Text(receiver.name)
                                        .font(.body)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("Or Enter an Address")
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
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
            .navigationTitle("Choose a Blittie Screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
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
