import SwiftUI
import AppKit
import SignalingCore
import Foundation

// With no --youtube-url argument, Receiver starts as a daemon: no window,
// listening on ControlServer for a YouTube URL or a WebRTC SDP offer. With
// --youtube-url, it plays that video fullscreen once and quits when it ends
// — kept for quick manual testing without needing to drive the HTTP server.
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

        With no arguments, Receiver starts as a daemon listening on
        http://localhost:\(ControlServer.port) for POST /youtube (a YouTube
        URL body) or POST /offer (a WebRTC SDP offer body, answered
        synchronously in the response body).
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let youTubeURL = launchYouTubeURL {
            Task { await coordinator.startYouTube(url: youTubeURL, onEnd: .quitApp) }
        } else {
            ControlServer.start(coordinator: coordinator)
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
