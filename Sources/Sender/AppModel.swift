import Foundation
import Observation

enum SenderMode: String, CaseIterable, Identifiable {
    case video
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Send Video"
        case .mirror: "Mirror Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "play.rectangle.fill"
        case .mirror: "rectangle.on.rectangle"
        }
    }
}

@Observable
final class AppModel {
    var mode: SenderMode = .video
    var showReceiverSheet = false

    var receiverAddress: String? {
        didSet { UserDefaults.standard.set(receiverAddress, forKey: "vgaReceiverAddress") }
    }

    var hasReceiver: Bool { receiverAddress != nil }
    var receiverName: String { receiverAddress ?? "No receiver selected" }

    init() {
        receiverAddress = UserDefaults.standard.string(forKey: "vgaReceiverAddress")
    }

    // Accepts a bare host ("192.168.1.42" or "living-room.local") or a
    // host:port pair, defaulting to the Receiver's fixed control port when
    // none is given — Bonjour discovery will fill this in automatically in
    // a later phase.
    func connect(to input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"^[a-zA-Z0-9.\-:]+$"#, options: .regularExpression) != nil else {
            return false
        }
        receiverAddress = trimmed.contains(":") ? trimmed : "\(trimmed):8787"
        return true
    }
}

// LAN-only control surface on the Receiver (see ControlServer.swift): a
// URL, an SDP blob, or nothing as the raw POST body, mirroring the same
// endpoints the ShareExtension and the old web Sender used.
enum ReceiverClient {
    struct RequestFailed: Error {
        let statusCode: Int
        let body: String
    }

    static func sendVideo(url: String, to address: String) async throws {
        try await post(path: "youtube", body: Data(url.utf8), to: address)
    }

    // Returns false for a 409 (no active session for the control to apply
    // to) rather than throwing, since that's an expected, silent no-op.
    @discardableResult
    static func control(_ path: String, to address: String) async throws -> Bool {
        do {
            try await post(path: "control/\(path)", body: nil, to: address)
            return true
        } catch let error as RequestFailed where error.statusCode == 409 {
            return false
        }
    }

    private static func post(path: String, body: Data?, to address: String) async throws {
        guard let url = URL(string: "http://\(address)/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RequestFailed(statusCode: code, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
