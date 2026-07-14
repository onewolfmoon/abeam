import Cocoa
import UniformTypeIdentifiers

// Standalone from SignalingCore: this only ever sends a URL to Receiver's
// /youtube endpoint (see ControlServer.swift), so it has no need for
// WebKit or the WebRTC signaling flow the main Sender app uses.
final class ShareViewController: NSViewController {
    private let urlLabel = NSTextField(wrappingLabelWithString: "Loading shared link...")
    private let addressField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: " ")
    private let sendButton = NSButton(title: "Send to Receiver", target: nil, action: nil)
    private var sharedURL: URL?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        Task { await resolveSharedURL() }
    }

    private func buildUI() {
        let addressRow = labeledRow(label: "Receiver address", field: addressField)
        addressField.placeholderString = "e.g. 192.168.1.42:8787"
        addressField.stringValue = UserDefaults.standard.string(forKey: "vgaReceiverAddress") ?? ""

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

    private func resolveSharedURL() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
            urlLabel.stringValue = "No link found in this share."
            return
        }
        do {
            let loaded = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            guard let url = loaded as? URL else {
                urlLabel.stringValue = "No link found in this share."
                return
            }
            sharedURL = url
            urlLabel.stringValue = url.absoluteString
            sendButton.isEnabled = true
        } catch {
            urlLabel.stringValue = "Couldn't read the shared link: \(error.localizedDescription)"
        }
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func sendTapped() {
        guard let sharedURL else { return }
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            statusLabel.stringValue = "enter the receiver's address first"
            return
        }
        UserDefaults.standard.set(address, forKey: "vgaReceiverAddress")

        sendButton.isEnabled = false
        statusLabel.stringValue = "sending to receiver..."
        Task {
            do {
                try await send(url: sharedURL, toReceiverAt: address)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                statusLabel.stringValue = "error: \(error.localizedDescription)"
                sendButton.isEnabled = true
            }
        }
    }

    private func send(url: URL, toReceiverAt address: String) async throws {
        guard let endpoint = URL(string: "http://\(address)/youtube") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(url.absoluteString.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ShareExtension", code: code, userInfo: [
                NSLocalizedDescriptionKey: "receiver returned \(code)"
            ])
        }
    }
}
