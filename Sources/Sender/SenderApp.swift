import SwiftUI
import SignalingCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct SenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var page = BrowserPage()

    var body: some Scene {
        WindowGroup {
            BrowserView(page)
                .frame(minWidth: 720, minHeight: 640)
                .task {
                    await page.load(URLRequest(url: SignalingPage.url(for: .sender)))
                }
        }
    }
}
