import SwiftUI
import AppKit
import SignalingCore
import ReceiverProtocol

// Abaft runs as a daemon: no window, listening on ReceiverSocketServer for a
// video share payload or a WebRTC SDP offer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    private var socketServer: ReceiverSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        socketServer = ReceiverSocketServer.start(coordinator: coordinator)
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
