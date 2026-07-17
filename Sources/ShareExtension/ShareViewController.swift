import Cocoa
import UniformTypeIdentifiers
import ReceiverProtocol

// Standalone from SignalingCore: this only ever sends a video message to
// Receiver (see ReceiverSocketServer.swift), so it has no need for WebKit or
// the WebRTC signaling flow the main BlittieProjector app uses. Depends only on
// ReceiverProtocol, not SignalingCore, so that stays structurally true
// rather than relying on the linker to dead-strip WebKit.
//
// blittieReceiverAddress isn't actually shared with the main BlittieProjector
// app today — there's no app group configured, so this UserDefaults key is a
// separate, extension-local value despite the same key name. Pre-existing,
// orthogonal to this file.
final class ShareViewController: NSViewController {
    private let urlLabel = NSTextField(wrappingLabelWithString: "Loading shared link...")
    private let addressField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: " ")
    private let sendButton = NSButton(title: "Send to Blittie Screen", target: nil, action: nil)
    // Raw share payload — a URL, or freeform text with a link embedded in it
    // (e.g. Dropout's Share hands over "I'm watching X on Dropout\nhttps://...").
    // Sent verbatim; Screen's video parsers are responsible for interpreting it.
    private var sharedPayload: String?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        Task { await resolveSharedPayload() }
    }

    private func buildUI() {
        let addressRow = labeledRow(label: "Blittie Screen address", field: addressField)
        addressField.placeholderString = "e.g. 192.168.1.42:8787"
        if let saved = UserDefaults.standard.string(forKey: "blittieReceiverAddress"),
           let endpoint = ReceiverEndpoint(persistedString: saved) {
            addressField.stringValue = endpoint.displayName
        }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = false

        let buttonRow = NSStackView(views: [cancelButton, sendButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [urlLabel, addressRow, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
    }

    private func labeledRow(label: String, field: NSTextField) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        labelField.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row = NSStackView(views: [labelField, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // Prefers a URL-typed attachment (most apps' share sheets, e.g. YouTube's)
    // but falls back to plain text (e.g. Dropout's Share, which hands over
    // freeform text like "I'm watching X on Dropout\nhttps://..." rather than
    // a distinct URL attachment). Either way the raw payload is forwarded
    // as-is — Screen's video parsers do the actual interpretation.
    private func resolveSharedPayload() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem, let attachments = item.attachments else {
            urlLabel.stringValue = "No supported video link found in this share."
            return
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            do {
                if let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    present(payload: url.absoluteString)
                    return
                }
            } catch {
                urlLabel.stringValue = "Couldn't read the shared link: \(error.localizedDescription)"
                return
            }
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            do {
                if let text = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    present(payload: text)
                    return
                }
            } catch {
                urlLabel.stringValue = "Couldn't read the shared text: \(error.localizedDescription)"
                return
            }
        }

        urlLabel.stringValue = "No supported video link found in this share."
    }

    private func present(payload: String) {
        sharedPayload = payload
        urlLabel.stringValue = payload
        sendButton.isEnabled = true
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func sendTapped() {
        guard let sharedPayload else { return }
        let addressInput = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = ReceiverEndpoint(manualInput: addressInput) else {
            statusLabel.stringValue = "enter the Blittie Screen's address first"
            return
        }
        UserDefaults.standard.set(endpoint.persistedString, forKey: "blittieReceiverAddress")

        sendButton.isEnabled = false
        statusLabel.stringValue = "sending to Blittie Screen..."
        Task {
            do {
                try await send(payload: sharedPayload, to: endpoint)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                statusLabel.stringValue = "error: \(error.localizedDescription)"
                sendButton.isEnabled = true
            }
        }
    }

    private func send(payload: String, to endpoint: ReceiverEndpoint) async throws {
        let connection = ReceiverConnection()
        try await connection.connectAndWaitUntilReady(to: endpoint.nwEndpoint)
        defer { Task { await connection.disconnect() } }
        switch try await connection.send(.video(payload: payload)) {
        case .ok:
            return
        case .error(let message):
            throw NSError(domain: "ShareExtension", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        case .answer, .notHandled:
            throw NSError(domain: "ShareExtension", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected response from Blittie Screen"
            ])
        }
    }
}
