import Foundation

// Talks to Receiver's ControlServer (see vga/Sources/Receiver/ControlServer.swift):
// LAN-only, unauthenticated, plain HTTP. Same trust model as the macOS Sender.
public enum ControlClientError: Error, LocalizedError {
    case invalidAddress
    case noActiveSession
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "enter the receiver's address first"
        case .noActiveSession:
            return "no video is currently playing on the receiver"
        case .http(let status, let body):
            return "receiver returned \(status): \(body)"
        }
    }
}

public enum ControlClient {
    // Mirrors Receiver's SessionCoordinator.PlaybackControl (see
    // vga/Sources/Receiver/ControlServer.swift's /control/* routes).
    public enum PlaybackControl: String {
        case playPause = "play-pause"
        case seekBack = "seek-back"
        case seekForward = "seek-forward"
    }

    public static func sendYouTubeURL(_ urlString: String, toReceiverAt address: String) async throws {
        var request = try request(address: address, path: "/youtube")
        request.httpBody = Data(urlString.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response, data: data)
    }

    // Receiver returns 409 when there's no active YouTube session (or its
    // video isn't ready yet) for the control to apply to.
    public static func sendControl(_ control: PlaybackControl, toReceiverAt address: String) async throws {
        let request = try request(address: address, path: "/control/\(control.rawValue)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            throw ControlClientError.noActiveSession
        }
        try checkOK(response, data: data)
    }

    private static func request(address: String, path: String) throws -> URLRequest {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "http://\(trimmed)\(path)") else {
            throw ControlClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    private static func checkOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ControlClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
