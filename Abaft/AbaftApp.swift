import SwiftUI
import AppKit
import SignalingCore
import ReceiverProtocol
import Foundation

// With no --video-url argument, Abaft starts as a daemon: no window,
// listening on ReceiverSocketServer for a video share payload or a WebRTC
// SDP offer. With --video-url, it runs that payload through the video parser
// registry and plays it fullscreen once, quitting when it ends — kept for
// quick manual testing without needing to drive the socket server.
// Looking for a named flag (rather than positional arg 1) rather than
// erroring, since e.g. Xcode's "Document Versions Browser" debug setting
// injects its own -NSDocumentRevisionsDebugMode YES into every launch.
let launchVideoPayload: String? = {
    let args = CommandLine.arguments.dropFirst()
    guard let flagIndex = args.firstIndex(of: "--video-url") else { return nil }
    let valueIndex = args.index(after: flagIndex)
    guard valueIndex < args.endIndex else {
        FileHandle.standardError.write(Data("""
        Usage: Abaft [--video-url <url-or-share-text>]

        With no arguments, Abaft starts as a daemon listening on a
        WebSocket at ws://localhost:\(ReceiverEndpoint.defaultPort), also
        advertised over Bonjour as \(ReceiverEndpoint.serviceType). Accepts a
        JSON-enveloped video share payload, WebRTC SDP offer, or playback
        control (see ReceiverProtocol.WireProtocol).
        With --video-url, it plays that payload (any link a registered
        VideoParser recognizes) fullscreen once and quits when it ends.
        Other/unknown arguments are ignored.

        Example:
          Abaft --video-url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        """.utf8))
        exit(1)
    }
    return args[valueIndex]
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    private var socketServer: ReceiverSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let launchVideoPayload {
            Task {
                let started = await coordinator.startVideo(payload: launchVideoPayload, onEnd: .quitApp)
                if !started {
                    FileHandle.standardError.write(Data("No video parser recognized: \(launchVideoPayload)\n".utf8))
                    exit(1)
                }
            }
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
struct AbaftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // No WindowGroup: it would show a window unconditionally at launch and
    // quit the app when it's closed. SessionCoordinator manages windows
    // imperatively instead. Settings gives the App protocol a scene without
    // either of those behaviors.
    //
    // There's nothing to configure, so the standard Settings… (Cmd+,) menu
    // item is removed rather than left pointing at an empty window.
    //
    // Abaft also has no editable text anywhere and no document/print model
    // — windows are managed imperatively by SessionCoordinator, not via
    // File > New — so the standard File/Edit menu boilerplate that SwiftUI
    // supplies by default is entirely inapplicable and removed too.
    //
    // No Help menu item either: there's no help content, and a per-app Help
    // entry isn't the right entry point for the Blittie system as a whole.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }
            CommandGroup(replacing: .printItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .help) { }
        }
    }
}
