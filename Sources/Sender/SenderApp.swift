import SwiftUI
import WebKit
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
    @State private var page = WebPage()

    var body: some Scene {
        WindowGroup {
            WebView(page)
                .frame(minWidth: 720, minHeight: 640)
                .onAppear {
                    page.load(URLRequest(url: SignalingPage.url(for: .sender)))
                }
        }
    }
}
