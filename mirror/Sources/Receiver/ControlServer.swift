import FlyingFox
import Foundation

// LAN-only control surface, same trust model as the existing copy/paste SDP
// exchange (no auth, no STUN/TURN). Two raw-body endpoints rather than one
// typed one, since the payloads (a URL, an SDP blob) are natural strings and
// callers can `curl --data-binary` them directly.
enum ControlServer {
    static let port: UInt16 = 8787

    @MainActor
    static func start(coordinator: SessionCoordinator) {
        let server = HTTPServer(port: port)

        Task {
            await server.appendRoute("POST /youtube") { request in
                let body = try await request.bodyData
                guard let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http") else {
                    return HTTPResponse(statusCode: .badRequest, body: Data("invalid youtube url".utf8))
                }
                await coordinator.startYouTube(url: url, onEnd: .closeWindow)
                return HTTPResponse(statusCode: .ok)
            }

            await server.appendRoute("POST /offer") { request in
                let body = try await request.bodyData
                guard let offerText = String(data: body, encoding: .utf8), !offerText.isEmpty else {
                    return HTTPResponse(statusCode: .badRequest, body: Data("missing offer body".utf8))
                }
                do {
                    let answer = try await coordinator.startOffer(offerText, onEnd: .closeWindow)
                    return HTTPResponse(statusCode: .ok, body: Data(answer.utf8))
                } catch {
                    return HTTPResponse(statusCode: .internalServerError, body: Data("\(error)".utf8))
                }
            }

            do {
                try await server.run()
            } catch {
                FileHandle.standardError.write(Data("Receiver control server failed: \(error)\n".utf8))
            }
        }
    }
}
