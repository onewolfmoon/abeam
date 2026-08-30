import Foundation
import ReceiverProtocol
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var sharedURLText: String?
    @State private var receiver: ReceiverEndpoint? = ReceiverEndpointStore
        .current
    @State private var showPicker = false
    @State private var isSending = false
    @State private var statusMessage: String?

    private let connection = ReceiverConnection()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sharedURLText {
                        Text(sharedURLText)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }

                Section("Screen") {
                    Button {
                        showPicker = true
                    } label: {
                        LabeledContent(
                            "Screen",
                            value: receiver?.displayName ?? "Choose Screen"
                        )
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Abeam to Receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: cancel) {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .disabled(!canSend)
                }
            }
            .sheet(isPresented: $showPicker) {
                ExtensionReceiverPickerSheet(receiver: $receiver)
            }
        }
        .task { await loadSharedURL() }
        .onChange(of: receiver) { _, newValue in
            ReceiverEndpointStore.current = newValue
        }
    }

    private var canSend: Bool {
        guard let sharedURLText, !sharedURLText.isEmpty else { return false }
        return receiver != nil && !isSending
    }

    /// Extracts the URL from the shared content.
    ///
    /// YouTube attaches a thumbnail image and a link, so the URL isn't
    /// necessarily first.
    private func loadSharedURL() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        {
            // loadObject(ofClass:) is the non-deprecated replacement, but it
            // fails to coerce public.plain-text items to NSString even when
            // canLoadObject reports true. In the Xcode 27 beta, this is
            // NSItemProviderErrorDomain -1200.
            if let url = try? await provider.loadItem(
                forTypeIdentifier: UTType.url.identifier
            ) as? URL {
                sharedURLText = url.absoluteString
                return
            }
        }
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(
            UTType.plainText.identifier
        ) {
            if let text = try? await provider.loadItem(
                forTypeIdentifier: UTType.plainText.identifier
            ) as? String {
                // Apps like Dropout share a sentence with a URL embedded in
                // it rather than a proper URL attachment, so pull the URL
                // out instead of sending the whole sentence as the payload.
                sharedURLText = Self.firstURL(in: text) ?? text
                return
            }
        }
        sharedURLText = ""
    }

    private static func firstURL(in text: String) -> String? {
        guard
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            )
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url?
            .absoluteString
    }

    private func send() {
        guard let payload = sharedURLText, let receiver else { return }
        isSending = true
        statusMessage = "sending to receiver…"
        Task {
            do {
                try await connection.connectAndWaitUntilReady(
                    to: receiver.nwEndpoint
                )
                switch try await connection.send(.video(payload: payload)) {
                case .ok:
                    finish()
                case .error(let message):
                    statusMessage = "error: \(message)"
                    isSending = false
                case .answer, .notHandled:
                    statusMessage = "receiver didn't accept the video"
                    isSending = false
                }
            } catch {
                statusMessage = "error: \(error.localizedDescription)"
                isSending = false
            }
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct ExtensionReceiverPickerSheet: View {
    @Binding var receiver: ReceiverEndpoint?
    @State private var manualAddress = ""
    @State private var connectError: String?
    @State private var browser = ReceiverBrowser()
    @State private var discovered: [DiscoveredReceiver] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Nearby screens") {
                    if discovered.isEmpty {
                        Text(
                            "No screens found. Enter an address below to connect."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovered) { receiver in
                            Button {
                                select(.bonjour(name: receiver.name))
                            } label: {
                                Label(receiver.name, systemImage: "tv")
                            }
                        }
                    }
                }

                Section("Screen by IP address") {
                    TextField(
                        "Address",
                        text: $manualAddress,
                        prompt: Text("e.g. 192.168.1.42 or living-room.local")
                    )
                    .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(
                            manualAddress.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )

                    if let connectError {
                        Text(connectError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Choose a screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
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

    private func select(_ endpoint: ReceiverEndpoint) {
        receiver = endpoint
        connectError = nil
        dismiss()
    }

    private func connect() {
        guard let endpoint = ReceiverEndpoint(manualInput: manualAddress) else {
            connectError = "Enter an IP address or hostname."
            return
        }
        select(endpoint)
    }
}
