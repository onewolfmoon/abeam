import SwiftUI
import AppKit
import SignalingCore
import ReceiverProtocol
import Foundation

// With no --youtube-url argument, Receiver starts as a daemon: no window,
// listening on ReceiverSocketServer for a YouTube URL or a WebRTC SDP offer.
// With --youtube-url, it plays that video fullscreen once and quits when it
// ends — kept for quick manual testing without needing to drive the socket
// server.
// Looking for a named flag (rather than positional arg 1) rather than
// erroring, since e.g. Xcode's "Document Versions Browser" debug setting
// injects its own -NSDocumentRevisionsDebugMode YES into every launch.
let launchYouTubeURL: URL? = {
    let args = CommandLine.arguments.dropFirst()
    guard let flagIndex = args.firstIndex(of: "--youtube-url") else { return nil }
    let valueIndex = args.index(after: flagIndex)
    guard valueIndex < args.endIndex,
          let url = URL(string: args[valueIndex]), let scheme = url.scheme, scheme.hasPrefix("http") else {
        FileHandle.standardError.write(Data("""
        Usage: swift run Receiver [--youtube-url <url>]

        With no arguments, Receiver starts as a daemon listening on a
        WebSocket at ws://localhost:\(ReceiverEndpoint.defaultPort), also
        advertised over Bonjour as \(ReceiverEndpoint.serviceType). Accepts a
        JSON-enveloped youtube URL, WebRTC SDP offer, or playback control
        (see ReceiverProtocol.WireProtocol).
        With --youtube-url, it plays that video fullscreen once and quits
        when it ends. Other/unknown arguments are ignored.

        Example:
          swift run Receiver --youtube-url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        """.utf8))
        exit(1)
    }
    return url
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    private var socketServer: ReceiverSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let youTubeURL = launchYouTubeURL {
            Task { await coordinator.startYouTube(url: youTubeURL, onEnd: .quitApp) }
        } else {
            socketServer = ReceiverSocketServer.start(coordinator: coordinator)
        }
    }

    // Sessions close their own window when they end; that must not take the
    // whole daemon down with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct ReceiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // No WindowGroup: it would show a window unconditionally at launch and
    // quit the app when it's closed. SessionCoordinator manages windows
    // imperatively instead. Settings gives the App protocol a scene without
    // either of those behaviors.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
