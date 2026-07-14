import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingController = NSHostingController(rootView: PlayerView(url: AppArguments.youTubeURL))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.title = "YouTube"
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
