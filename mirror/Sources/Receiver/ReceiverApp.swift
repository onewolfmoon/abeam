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
                .task {
                    await watchForDisconnect()
                }
        }
    }

    // No JS->Swift push messaging in the new WebKit-for-SwiftUI API has been
    // verified yet, so this polls connection state via the confirmed-working
    // Swift->JS callJavaScript bridge instead of waiting for a pushed event.
    private func watchForDisconnect() async {
        var sawConnected = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard let result = try? await page.callJavaScript(
                "return window.__vgaConnectionState ? window.__vgaConnectionState() : 'none';"
            ) else { continue }
            let state = (result as? String) ?? "none"
            if state == "connected" {
                sawConnected = true
            } else if sawConnected && (state == "disconnected" || state == "failed" || state == "closed") {
                NSApplication.shared.terminate(nil)
                return
            }
        }
    }
}
