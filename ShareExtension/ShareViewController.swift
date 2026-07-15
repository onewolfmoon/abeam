import SenderKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Standalone from the main app's ContentView: this only ever sends a URL to
// Receiver's /youtube endpoint (see vga/Sources/Receiver/ControlServer.swift),
// reusing SenderKit's ControlClient/ReceiverAddressStore. Mirrors vga's macOS
// ShareViewController, but as a UIKit host for a small SwiftUI form since
// that's the natural fit for an iOS share extension.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(extensionContext: extensionContext)
        let hosting = UIHostingController(rootView: ShareView(model: model))
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var urlText: String = "Loading shared link..."
    @Published var receiverAddress: String = ReceiverAddressStore.address
    @Published var status: String = ""
    @Published var isSending = false
    @Published var canSend = false

    private weak var extensionContext: NSExtensionContext?
    private var sharedURL: URL?

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
        Task { await resolveSharedURL() }
    }

    // Native apps' share sheets (unlike Safari's page-sharing extension point)
    // hand us either a `public.url` item or, for some apps, the link as
    // `public.plain-text` — so both are checked here.
    private func resolveSharedURL() async {
        guard let attachments = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments else {
            urlText = "No link found in this share."
            return
        }
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
           let url = loaded as? URL {
            accept(url)
            return
        }
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
           let text = loaded as? String,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme, scheme.hasPrefix("http") {
            accept(url)
            return
        }
        urlText = "No link found in this share."
    }

    private func accept(_ url: URL) {
        sharedURL = url
        urlText = url.absoluteString
        canSend = true
    }

    func send() {
        guard let sharedURL else { return }
        let address = receiverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            status = "enter the receiver's address first"
            return
        }
        ReceiverAddressStore.address = address

        isSending = true
        status = "sending to receiver..."
        Task {
            defer { isSending = false }
            do {
                try await ControlClient.sendYouTubeURL(sharedURL.absoluteString, toReceiverAt: address)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                status = "error: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    Text(model.urlText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Receiver address") {
                    TextField("e.g. 192.168.1.42:8787", text: $model.receiverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Send to Receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Button("Send") { model.send() }
                            .disabled(!model.canSend)
                    }
                }
            }
        }
    }
}
