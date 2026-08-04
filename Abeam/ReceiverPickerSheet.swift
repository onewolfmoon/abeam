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
                Section(header: Text("Nearby screens")) {
                    if discovered.isEmpty {
                        Text(
                            "No screens found. Enter an address below to connect."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        #if os(macOS)
                            LabeledContent("Screen") {
                                VStack(alignment: .leading) {
                                    ForEach(discovered) { receiver in
                                        Button {
                                            select(receiver)
                                        } label: {
                                            Label(
                                                receiver.name,
                                                systemImage: "tv"
                                            )
                                        }
                                    }
                                }
                            }
                        #else
                            ForEach(discovered) { receiver in
                                Button {
                                    select(receiver)
                                } label: {
                                    Label(receiver.name, systemImage: "tv")
                                }
                            }
                        #endif
                    }
                }

                #if os(macOS)
                    Divider()
                #endif

                Section(header: Text("Screen by IP address")) {
                    TextField(
                        "Address",
                        text: $manualAddress,
                        prompt: Text(
                            "e.g. 192.168.1.42 or living-room.local"
                        ),
                    )
                    .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(
                            manualAddress.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        #if os(macOS)
                            .buttonStyle(.borderedProminent)
                        #endif

                    if let connectError {
                        Text(connectError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect to a screen")
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
