import AppKit
import ReceiverProtocol
import SignalingCore
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    let receiverInfo = ReceiverServerInfo()
    private var socketServer: ReceiverSocketServer?
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        socketServer = ReceiverSocketServer.start(
            coordinator: coordinator,
            info: receiverInfo
        )
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
        Settings {
            SettingsView(
                updater: appDelegate.updaterController.updater,
                receiverInfo: appDelegate.receiverInfo
            )
        }
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .importExport) {}
                CommandGroup(replacing: .printItem) {}
                CommandGroup(replacing: .undoRedo) {}
                CommandGroup(replacing: .pasteboard) {}
                CommandGroup(replacing: .textEditing) {}
                CommandGroup(replacing: .help) {}
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: appDelegate.updaterController.updater)
                }
            }
    }
}
