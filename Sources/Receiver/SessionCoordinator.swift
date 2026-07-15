import AppKit
import SwiftUI
import SignalingCore
import IOKit.pwr_mgt

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

    enum PlaybackControl {
        case playPause
        case seekBack
        case seekForward
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
    private var onEnd: EndBehavior = .closeWindow
    // nonisolated(unsafe): Timer/the monitor token aren't Sendable-exempt the
    // way AppKit's own @MainActor types (e.g. NSWindow above) are, which
    // would otherwise break this class's Sendable conformance. Safe here
    // since both are only ever touched from this MainActor-isolated class.
    private nonisolated(unsafe) var cursorMoveMonitor: Any?
    private nonisolated(unsafe) var cursorHideTimer: Timer?
    private var displayAssertionID: IOPMAssertionID?

    func startYouTube(url: URL, onEnd: EndBehavior) async {
        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        fullscreenStrategy = .element
        self.onEnd = onEnd
        prepareWindow(page: page)
        watchTask = Task {
            await Self.prepareYouTube(page, url: url)
            await self.presentAndWatch(page: page, isEnded: Self.isVideoEnded)
        }
    }

    @discardableResult
    func startOffer(_ offerText: String, onEnd: EndBehavior) async throws -> String {
        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        fullscreenStrategy = .window
        self.onEnd = onEnd
        prepareWindow(page: page)
        await Self.load(page, request: URLRequest(url: SignalingPage.url(for: .receiver)))

        guard let answer = try await page.callJavaScript(
            "return await window.__vgaAcceptOffer(offer);",
            arguments: ["offer": offerText]
        ) as? String else {
            throw SessionError.noAnswer
        }

        watchTask = Task {
            await self.presentAndWatch(page: page, isEnded: Self.isMirrorDisconnected)
        }

        return answer
    }

    // Drives the currently playing YouTube video's <video> element directly,
    // rather than dispatching synthetic KeyboardEvents at the page: those
    // aren't isTrusted, and YouTube's own keyboard-shortcut handling isn't
    // guaranteed to react to them. Restricted to the YouTube (.element)
    // strategy — the mirror path's <video> renders a live incoming
    // MediaStream, where play/pause/seek don't have meaningful semantics.
    func sendControl(_ control: PlaybackControl) async -> Bool {
        guard case .element = fullscreenStrategy, let page else { return false }
        return await Self.applyControl(control, to: page)
    }

    // Ends the active YouTube session the same way a natural video-end does:
    // same fullscreen-exit + window-close sequence, same onEnd behavior.
    // Restricted to the YouTube (.element) strategy, matching sendControl.
    @discardableResult
    func stop() async -> Bool {
        guard case .element = fullscreenStrategy, let page, let window else { return false }
        watchTask?.cancel()
        watchTask = nil
        await finishSession(page: page, window: window)
        return true
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
        releaseDisplayAssertion()
    }

    private func presentAndWatch(
        page: BrowserPage,
        isEnded: @escaping (BrowserPage) async -> Bool
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
            armCursorAutoHide()
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if await isEnded(page) { break }
        }
        guard !Task.isCancelled else { return }

        watchTask = nil
        if let window {
            await finishSession(page: page, window: window)
        } else {
            self.page = nil
            applyEndBehavior()
        }
    }

    // Shared by presentAndWatch's natural-end path and stop(): tears down the
    // window the same way regardless of what triggered the end.
    private func finishSession(page: BrowserPage, window: NSWindow) async {
        await exitFullscreenAndClose(page: page, window: window)
        self.window = nil
        self.page = nil
        releaseDisplayAssertion()
        applyEndBehavior()
    }

    private func applyEndBehavior() {
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
        Self.wakeDisplay()
        acquireDisplayAssertion()
        window.center()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Wakes a sleeping display and resets the system's idle-sleep timer, the
    // same mechanism `caffeinate -u` relies on. Called right before a session
    // is revealed so a monitor that dozed off while waiting for a connection
    // comes back for the mirror/video that's about to show on it. This alone
    // doesn't keep the display awake afterwards — that's what the held
    // assertion below is for.
    private static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "VGA Receiver starting playback" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }

    // Held for the duration of a session so the display doesn't sleep
    // mid-mirror or mid-video; released whenever a session ends, by whatever
    // path ends it (natural end, stop(), an interrupting new session, or app
    // quit tearing down the last one). Unlike wakeDisplay() above, this
    // assertion type only *prevents* sleep — it won't rouse an already
    // sleeping display, which is why both are needed.
    private func acquireDisplayAssertion() {
        guard displayAssertionID == nil else { return }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "VGA Receiver mirroring/playback" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            displayAssertionID = assertionID
        }
    }

    private func releaseDisplayAssertion() {
        guard let displayAssertionID else { return }
        IOPMAssertionRelease(displayAssertionID)
        self.displayAssertionID = nil
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

    // 5 seconds matches YouTube's own left/right arrow-key shortcut, so the
    // remote buttons feel like the real thing.
    private static func applyControl(_ control: PlaybackControl, to page: BrowserPage) async -> Bool {
        let js: String
        switch control {
        case .playPause:
            js = """
                var v = document.querySelector('video');
                if (!v) return false;
                if (v.paused) { v.play(); } else { v.pause(); }
                return true;
                """
        case .seekBack:
            js = """
                var v = document.querySelector('video');
                if (!v) return false;
                v.currentTime = Math.max(0, v.currentTime - 5);
                return true;
                """
        case .seekForward:
            js = """
                var v = document.querySelector('video');
                if (!v) return false;
                v.currentTime = Math.min(v.duration || Infinity, v.currentTime + 5);
                return true;
                """
        }
        let result = try? await page.callJavaScript(js)
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
            disarmCursorAutoHide()
            window.close()
        }
    }

    // The mirror path's window-level fullscreen (see FullscreenStrategy above)
    // never sets document.fullscreenElement, so WebKit's own idle-hide-cursor
    // behavior for fullscreen video never engages — that behavior is tied to
    // the Fullscreen API, not merely to a video filling the window. Reproduce
    // it natively instead: hide the cursor immediately, then re-hide it after
    // each period of no movement, matching a native fullscreen video player.
    private func armCursorAutoHide() {
        window?.acceptsMouseMovedEvents = true
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.scheduleCursorHide()
            return event
        }
    }

    private func scheduleCursorHide() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func disarmCursorAutoHide() {
        if let cursorMoveMonitor {
            NSEvent.removeMonitor(cursorMoveMonitor)
        }
        cursorMoveMonitor = nil
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
    }
}
