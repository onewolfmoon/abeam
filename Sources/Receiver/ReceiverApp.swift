import SwiftUI
import WebKit
import AppKit
import SignalingCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
        // toggleFullScreen right at launch can silently no-op before the
        // window has fully appeared, so give it a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let window = NSApp.windows.first, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
}

@main
struct ReceiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var page = WebPage()

    var body: some Scene {
        WindowGroup {
            WebView(page)
                .ignoresSafeArea()
                .onAppear {
                    page.load(URLRequest(url: SignalingPage.url(for: .receiver)))
                }
        }
    }
}
