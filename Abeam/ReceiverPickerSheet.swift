import ReceiverProtocol
import SwiftUI

struct ReceiverPickerSheet: View {
    @Bindable var model: AppModel
    @State private var manualAddress = ""
    @State private var connectError: String?
    @State private var browser = ReceiverBrowser()
    @State private var discovered: [DiscoveredReceiver] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Nearby Receivers")) {
                    if discovered.isEmpty {
                        Text(
                            "No Receivers found. Enter an address below to connect."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        screensList
                    }
                }

                #if os(macOS)
                    Divider()
                #endif

                Section(header: Text("Receiver by IP address")) {
                    TextField(
                        "Address",
                        text: $manualAddress,
                        prompt: Text(
                            "e.g. 192.168.1.42 or living-room.local"
                        ),
                    )
                    .onSubmit(connect)
                    connectButton

                    if let connectError {
                        Text(connectError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect to a Receiver")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Label("Cancel", systemImage: "xmark")
                            #if os(macOS)
                                .labelStyle(.titleOnly)
                            #endif
                    }.keyboardShortcut(.cancelAction)
                }
            }
            // macOS modals have no padding by default, but adding padding on iOS insets the form on a white background that takes over the page header.
            #if os(macOS)
                .padding()
            #endif
        }
        .onAppear {
            if case .manual = model.receiverEndpoint {
                manualAddress = model.receiverEndpoint?.displayName ?? ""
            }
        }
        .task {
            await browser.start()
            for await results in await browser.resultsUpdates() {
                guard !Task.isCancelled else { return }
                discovered = results
            }
        }
        .onDisappear {
            let browser = browser
            Task { await browser.stop() }
        }
    }

    @ViewBuilder
    private var screensList: some View {
        #if os(macOS)
            LabeledContent("Receiver") {
                VStack(alignment: .leading) {
                    ForEach(discovered) { receiver in
                        screenButton(for: receiver)
                    }
                }
            }
        #else
            ForEach(discovered) { receiver in
                screenButton(for: receiver)
            }
        #endif
    }

    private func screenButton(for receiver: DiscoveredReceiver) -> some View {
        Button {
            select(receiver)
        } label: {
            Label(receiver.name, systemImage: "tv")
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        Button("Connect", action: connect)
            .disabled(
                manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            #if os(macOS)
                .buttonStyle(.borderedProminent)
            #endif
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
