import AppKit
import SwiftUI
import SignalingCore

struct SessionWindowView: View {
    let page: BrowserPage

    var body: some View {
        BrowserView(page)
            .ignoresSafeArea()
    }
}

// Owns whichever session (YouTube playback or WebRTC mirror) is currently
// showing. Starting a new session always tears down whatever's running
// first, which is what makes an interrupting payload "just work": the old
// session's watch task gets cancelled and its window closed before the new
// one begins.
// Sendable because all mutable state is isolated to MainActor; this lets
// route handler closures in ControlServer (which FlyingFox requires to be
// @Sendable) capture and call it directly.
@MainActor
final class SessionCoordinator: Sendable {
    enum EndBehavior {
        case closeWindow
        case quitApp
    }

    enum SessionError: Error {
        case noAnswer
    }

    // YouTube uses HTML element Fullscreen (requestFullscreen() on the
    // <video>). The WebRTC mirror path uses window-level fullscreen instead:
    // element Fullscreen reparents its content into a separate native
    // fullscreen presentation surface, and a live MediaStream-backed <video>
    // (like receiver.html's #remoteVideo) doesn't reliably keep rendering
    // into that new surface — it goes black while playback/audio/controls
    // continue normally underneath. Window-level fullscreen just moves the
    // same window (and its live WebView layer) into its own Space, so
    // nothing gets reparented.
    private enum FullscreenStrategy {
        case element
        case window
    }

    private var watchTask: Task<Void, Never>?
    private var window: NSWindow?
    private var page: BrowserPage?
    private var fullscreenStrategy: FullscreenStrategy = .element

    func startYouTube(url: URL, onEnd: EndBehavior) async {
        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        fullscreenStrategy = .element
        prepareWindow(page: page)
        watchTask = Task {
            await Self.prepareYouTube(page, url: url)
            await self.presentAndWatch(page: page, isEnded: Self.isVideoEnded, onEnd: onEnd)
        }
    }

    @discardableResult
    func startOffer(_ offerText: String, onEnd: EndBehavior) async throws -> String {
        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        fullscreenStrategy = .window
        prepareWindow(page: page)
        await Self.load(page, request: URLRequest(url: SignalingPage.url(for: .receiver)))

        guard let answer = try await page.callJavaScript(
            "return await window.__vgaAcceptOffer(offer);",
            arguments: ["offer": offerText]
        ) as? String else {
            throw SessionError.noAnswer
        }

        watchTask = Task {
            await self.presentAndWatch(page: page, isEnded: Self.isMirrorDisconnected, onEnd: onEnd)
        }

        return answer
    }

    // MARK: - Session lifecycle

    // Exits any active fullscreen before closing the window. Skipping this
    // leaves the fullscreen transition's native chrome/Space half-torn-down,
    // which was observed to block the next session's window from appearing
    // at all.
    private func teardownCurrentSession() async {
        watchTask?.cancel()
        watchTask = nil
        if let page, let window {
            await exitFullscreenAndClose(page: page, window: window)
        } else {
            window?.close()
        }
        window = nil
        page = nil
    }

    private func presentAndWatch(
        page: BrowserPage,
        isEnded: @escaping (BrowserPage) async -> Bool,
        onEnd: EndBehavior
    ) async {
        // Best-effort readiness wait: proceed to show the window even if
        // this times out, rather than never showing anything for a page
        // that's stuck (consent dialogs, slow networks, etc).
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !Task.isCancelled, ContinuousClock.now < readyDeadline, !(await Self.isVideoPlaying(page)) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }

        reveal()

        // Give the player UI a moment to settle before requesting fullscreen.
        try? await Task.sleep(for: .milliseconds(700))
        switch fullscreenStrategy {
        case .element:
            await Self.requestFullscreen(page)
            // If that didn't take (e.g. the player wasn't quite ready), try once more.
            try? await Task.sleep(for: .milliseconds(1200))
            if await !Self.isElementFullscreen(page) {
                await Self.requestFullscreen(page)
            }
        case .window:
            if let window, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if await isEnded(page) { break }
        }
        guard !Task.isCancelled else { return }

        watchTask = nil
        if let window {
            await exitFullscreenAndClose(page: page, window: window)
        }
        window = nil
        self.page = nil
        switch onEnd {
        case .closeWindow: break
        case .quitApp: NSApp.terminate(nil)
        }
    }

    // Creates and attaches the window's WebView immediately, before the page
    // ever navigates, but invisible (alpha 0) until reveal(). This matters,
    // not just cosmetics: WKWebView's element-fullscreen capability is fixed
    // by its configuration at the time the document loads, so a WebView
    // attached only after the video is already playing is too late —
    // requestFullscreen() silently no-ops on it. The window still needs to
    // be ordered onto screen for SwiftUI to actually realize the WebView,
    // not just construct it — alpha 0 (rather than an off-screen position)
    // keeps it invisible even though AppKit auto-repositions new windows
    // that would otherwise be entirely off-screen back into view.
    private func prepareWindow(page: BrowserPage) {
        let hostingController = NSHostingController(rootView: SessionWindowView(page: page))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.title = "Receiver"
        window.alphaValue = 0
        window.orderFront(nil)
        self.window = window
    }

    private func reveal() {
        guard let window else { return }
        window.center()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Mode-specific preparation

    private static func prepareYouTube(_ page: BrowserPage, url: URL) async {
        let navigationTask = Task<Void, Never> {
            await load(page, request: URLRequest(url: url))
        }
        let playbackTask = Task<Void, Never> {
            while !Task.isCancelled {
                if await isVideoPlaying(page) { return }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        // Proceed on whichever happens first: the page finishes loading, or
        // the video starts playing. A timeout guards against YouTube states
        // we didn't anticipate.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await navigationTask.value }
            group.addTask { await playbackTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            navigationTask.cancel()
            playbackTask.cancel()
            group.cancelAll()
        }
    }

    private static func load(_ page: BrowserPage, request: URLRequest) async {
        // Ignore navigation errors; readiness polling covers it.
        await page.load(request)
    }

    // MARK: - Shared JS predicates
    //
    // isVideoPlaying/requestFullscreen are used unmodified for both YouTube's
    // player and receiver.html's #remoteVideo: the mirror page already calls
    // remoteVideo.play() as soon as a WebRTC track arrives, so "is a <video>
    // actually playing" is the right readiness signal for both.

    private static func isVideoPlaying(_ page: BrowserPage) async -> Bool {
        let result = try? await page.callJavaScript("""
            var v = document.querySelector('video');
            return v ? (!v.paused && v.currentTime > 0) : false;
            """)
        return (result as? Bool) ?? false
    }

    private static func isVideoEnded(_ page: BrowserPage) async -> Bool {
        let result = try? await page.callJavaScript("""
            var v = document.querySelector('video');
            return v ? v.ended : false;
            """)
        return (result as? Bool) ?? false
    }

    // Only ever polled after isVideoPlaying has already been true once (see
    // presentAndWatch), so any disconnected/failed/closed state here is a
    // genuine drop of an established connection, not startup noise.
    private static func isMirrorDisconnected(_ page: BrowserPage) async -> Bool {
        let result = try? await page.callJavaScript(
            "return window.__vgaConnectionState ? window.__vgaConnectionState() : 'none';"
        )
        let state = (result as? String) ?? "none"
        return state == "disconnected" || state == "failed" || state == "closed"
    }

    private static func requestFullscreen(_ page: BrowserPage) async {
        _ = try? await page.callJavaScript("""
            var v = document.querySelector('video');
            if (v) { await v.requestFullscreen(); }
            """)
    }

    private static func isElementFullscreen(_ page: BrowserPage) async -> Bool {
        let result = try? await page.callJavaScript("return !!document.fullscreenElement;")
        return (result as? Bool) ?? false
    }

    private func exitFullscreenAndClose(page: BrowserPage, window: NSWindow) async {
        switch fullscreenStrategy {
        case .element:
            _ = try? await page.callJavaScript("""
                if (document.fullscreenElement) { await document.exitFullscreen(); }
                """)
            // Give the native fullscreen-exit transition a moment to finish
            // before tearing down the window/space it's animating out of.
            try? await Task.sleep(for: .milliseconds(400))
            window.close()
        case .window:
            // Closing a still-fullscreen window directly is a normal,
            // supported operation; no need to toggle out of fullscreen
            // first. Note: if a *new* session starts its own fullscreen
            // transition immediately after this (i.e. a mirror session gets
            // interrupted while fullscreen), macOS can take several seconds
            // in the background to fully retire this window's Space —
            // cosmetic (the old fullscreen Space lingers briefly in
            // Mission Control/window lists), not a functional block; the
            // new session's own window and fullscreen still work correctly
            // in the meantime.
            window.close()
        }
    }
}
