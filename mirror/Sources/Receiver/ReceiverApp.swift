import SwiftUI
import WebKit
import AppKit
import SignalingCore
import Foundation

// With no argument, Receiver starts the WebRTC mirror pairing UI. With a
// YouTube URL argument, it plays that video fullscreen and quits when it
// ends. Resolved once at launch so both the App and its delegate agree on
// which mode is active.
let launchYouTubeURL: URL? = {
    guard let arg = CommandLine.arguments.dropFirst().first else { return nil }
    guard let url = URL(string: arg), let scheme = url.scheme, scheme.hasPrefix("http") else {
        FileHandle.standardError.write(Data("""
        Usage: swift run Receiver [youtube-url]

        With no argument, Receiver starts the WebRTC mirror pairing UI.
        With a YouTube URL, it plays that video fullscreen and quits when it ends.

        Example:
          swift run Receiver "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        """.utf8))
        exit(1)
    }
    return url
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
        // In YouTube mode, YouTubePlayerView drives its own element
        // fullscreen once playback starts; window-level fullscreen here
        // would just fight it.
        guard launchYouTubeURL == nil else { return }
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
            if let youTubeURL = launchYouTubeURL {
                YouTubePlayerView(url: youTubeURL)
            } else {
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
