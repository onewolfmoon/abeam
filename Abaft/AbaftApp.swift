import AppKit
import ReceiverProtocol
import SignalingCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    private var socketServer: ReceiverSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        socketServer = ReceiverSocketServer.start(coordinator: coordinator)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // The application remains running in the dock when not actively displaying content.
        false
    }
}

@main
struct AbaftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Customizations:
        //
        // * Use `Settings` as the main scene to suppress any window from
        // appearing at startup. Windows will be shown imperatively.
        //
        // * Remove menus that don't apply to this app. Abaft isn't really an
        // interactive app other than through interactions with Abeam.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .importExport) {}
                CommandGroup(replacing: .printItem) {}
                CommandGroup(replacing: .undoRedo) {}
                CommandGroup(replacing: .pasteboard) {}
                CommandGroup(replacing: .textEditing) {}
                CommandGroup(replacing: .help) {}
            }
    }
}
