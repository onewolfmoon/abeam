import Foundation
import OSLog
import ReceiverProtocol
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ShareView: View {
    private nonisolated static let logger = Logger(
        subsystem: "dev.wolfmoon.Abeam.SendToAbaft", category: "ShareView"
    )

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

                Section("Receiver") {
                    Button {
                        showPicker = true
                    } label: {
                        LabeledContent(
                            "Receiver",
                            value: receiver?.displayName ?? "Choose Receiver"
                        )
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Send to Abeam Receiver")
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
        Self.logger.notice(
            "loadSharedURL: \(providers.count) attachment(s)"
        )
        for (index, provider) in providers.enumerated() {
            Self.logger.notice(
                "attachment \(index) types: \(provider.registeredTypeIdentifiers)"
            )
        }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        {
            // loadObject(ofClass:) is the documented replacement for
            // loadItem(forTypeIdentifier:), but in the Xcode 27 beta it
            // fails to coerce items to NSURL/NSString even when
            // canLoadObject reports true (NSItemProviderErrorDomain
            // -1200). Trying loadDataRepresentation(forTypeIdentifier:)
            // instead, on the theory that it's a different code path —
            // logging is here to confirm or refute that theory.
            if let data = await Self.loadDataRepresentation(
                from: provider, forTypeIdentifier: UTType.url.identifier
            ), let url = URL(dataRepresentation: data, relativeTo: nil) {
                sharedURLText = url.absoluteString
                return
            }
        }
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(
            UTType.plainText.identifier
        ) {
            if let data = await Self.loadDataRepresentation(
                from: provider, forTypeIdentifier: UTType.plainText.identifier
            ) {
                if let text = String(data: data, encoding: .utf8) {
                    // Apps like Dropout share a sentence with a URL embedded
                    // in it rather than a proper URL attachment, so pull the
                    // URL out instead of sending the whole sentence as the
                    // payload.
                    sharedURLText = Self.firstURL(in: text) ?? text
                    return
                } else {
                    let hex = data.prefix(32)
                        .map { String(format: "%02x", $0) }.joined()
                    Self.logger.error(
                        """
                        public.plain-text: UTF-8 decode failed; \
                        \(data.count) byte(s), hex: \(hex), lossy: \
                        \(String(decoding: data, as: UTF8.self))
                        """
                    )
                }
            }
        }
        Self.logger.error("loadSharedURL: no provider yielded a payload")
        sharedURLText = ""
    }

    /// Foundation doesn't provide an `async` overload of
    /// `loadDataRepresentation(forTypeIdentifier:)` — unlike `loadItem`,
    /// it returns an `NSProgress` rather than `Void`, so it isn't
    /// automatically bridged. Wrap the completion-handler form ourselves.
    private static func loadDataRepresentation(
        from provider: NSItemProvider, forTypeIdentifier typeIdentifier: String
    ) async -> Data? {
        logger.notice("loadDataRepresentation(\(typeIdentifier)): requesting")
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { data, error in
                logger.notice(
                    """
                    loadDataRepresentation(\(typeIdentifier)): completed \
                    \(data?.count ?? -1) byte(s), \
                    error: \(error.map(String.init(describing:)) ?? "nil")
                    """
                )
                continuation.resume(returning: data)
            }
        }
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
                Section("Nearby Receivers") {
                    if discovered.isEmpty {
                        Text(
                            "No Receivers found. Enter an address below to connect."
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

                Section("Receiver by IP address") {
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
            .navigationTitle("Choose a Receiver")
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
