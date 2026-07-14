import FlyingFox
import Foundation

// LAN-only control surface, same trust model as the existing copy/paste SDP
// exchange (no auth, no STUN/TURN). Two raw-body endpoints rather than one
// typed one, since the payloads (a URL, an SDP blob) are natural strings and
// callers can `curl --data-binary` them directly.
enum ControlServer {
    static let port: UInt16 = 8787

    // Sender's page (loaded from a bundled file:// resource) calls these
    // endpoints via fetch(), which is a cross-origin request from a WebView's
    // point of view — without this header the browser discards the response
    // before Sender's JS ever sees the answer body.
    private static let corsHeaders: HTTPHeaders = [HTTPHeader("Access-Control-Allow-Origin"): "*"]

    @MainActor
    static func start(coordinator: SessionCoordinator) {
        let server = HTTPServer(port: port)

        Task {
            await server.appendRoute("POST /youtube") { request in
                let body = try await request.bodyData
                guard let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http") else {
                    return await HTTPResponse(statusCode: .badRequest, headers: corsHeaders, body: Data("invalid youtube url".utf8))
                }
                await coordinator.startYouTube(url: url, onEnd: .closeWindow)
                return await HTTPResponse(statusCode: .ok, headers: corsHeaders)
            }

            await server.appendRoute("POST /offer") { request in
                let body = try await request.bodyData
                guard let offerText = String(data: body, encoding: .utf8), !offerText.isEmpty else {
                    return await HTTPResponse(statusCode: .badRequest, headers: corsHeaders, body: Data("missing offer body".utf8))
                }
                do {
                    let answer = try await coordinator.startOffer(offerText, onEnd: .closeWindow)
                    return await HTTPResponse(statusCode: .ok, headers: corsHeaders, body: Data(answer.utf8))
                } catch {
                    return await HTTPResponse(statusCode: .internalServerError, headers: corsHeaders, body: Data("\(error)".utf8))
                }
            }

            await server.appendRoute("POST /control/play-pause") { _ in
                await controlResponse(coordinator: coordinator, control: .playPause)
            }

            await server.appendRoute("POST /control/seek-back") { _ in
                await controlResponse(coordinator: coordinator, control: .seekBack)
            }

            await server.appendRoute("POST /control/seek-forward") { _ in
                await controlResponse(coordinator: coordinator, control: .seekForward)
            }

            do {
                try await server.run()
            } catch {
                FileHandle.standardError.write(Data("Receiver control server failed: \(error)\n".utf8))
            }
        }
    }

    // .conflict when there's no active YouTube session (or its video isn't
    // ready yet) for the control to apply to.
    @MainActor
    private static func controlResponse(coordinator: SessionCoordinator, control: SessionCoordinator.PlaybackControl) async -> HTTPResponse {
        let handled = await coordinator.sendControl(control)
        return await HTTPResponse(statusCode: handled ? .ok : .conflict, headers: corsHeaders)
    }
}
