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

struct NativeMirrorWindowView: View {
    let session: NativeMirrorSession

    var body: some View {
        NativeMirrorView(session: session)
            .ignoresSafeArea()
            .background(Color.black)
    }
}

// Owns whichever session (parsed-video playback or WebRTC mirror) is
// currently showing. Starting a new session always tears down whatever's
// running first, which is what makes an interrupting payload "just work":
// the old session's watch task gets cancelled and its window closed before
// the new one begins.
// Sendable because all mutable state is isolated to MainActor; this lets
// route handler closures in ControlServer (which FlyingFox requires to be
// @Sendable) capture and call it directly.
@MainActor
final class SessionCoordinator: Sendable {
    enum PlaybackControl {
        case playPause
        case seekBack
        case seekForward
    }

    // Parsed-video playback uses HTML element Fullscreen (requestFullscreen()
    // on the <video>) via the WebView it still runs in. The WebRTC mirror
    // path renders into a native NSView (NativeMirrorView) instead, which
    // has no HTML Fullscreen API at all — window-level fullscreen is the
    // only option there, so the two session kinds and the two
    // FullscreenStrategy cases are always 1:1 with each other.
    private enum FullscreenStrategy {
        case element
        case window
    }

    private var watchTask: Task<Void, Never>?
    private var window: NSWindow?
    private var page: BrowserPage?
    private var mirrorSession: NativeMirrorSession?
    private var activeParser: VideoParser?
    private var fullscreenStrategy: FullscreenStrategy = .element
    // nonisolated(unsafe): Timer/the monitor token aren't Sendable-exempt the
    // way AppKit's own @MainActor types (e.g. NSWindow above) are, which
    // would otherwise break this class's Sendable conformance. Safe here
    // since both are only ever touched from this MainActor-isolated class.
    private nonisolated(unsafe) var cursorMoveMonitor: Any?
    private nonisolated(unsafe) var cursorHideTimer: Timer?
    private var displayAssertionID: IOPMAssertionID?

    // Runs `payload` (whatever raw text the sending app's share sheet handed
    // over) through the video parser registry; returns false without
    // disturbing any currently-playing session if no parser claims it.
    @discardableResult
    func startVideo(payload: String) async -> Bool {
        guard let (url, parser) = VideoParserRegistry.default.parse(payload) else { return false }

        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        activeParser = parser
        fullscreenStrategy = .element
        prepareWindow(content: SessionWindowView(page: page))
        // Shown right away rather than held back until playback starts: the
        // page's own loading/consent/ad chrome is left visible on purpose,
        // so the user sees this is a real automated web view rather than
        // something dressed up to look otherwise.
        reveal()
        watchTask = Task {
            await self.presentAndWatch(page: page, parser: parser, url: url)
        }
        return true
    }

    // Native analog of receiver.html's acceptOffer: hands the offer straight
    // to NativeMirrorSession (RTCPeerConnection, no WebView involved) and
    // returns the answer SDP.
    @discardableResult
    func startOffer(_ offerText: String) async throws -> String {
        await teardownCurrentSession()

        let (session, answerSDP) = try await NativeMirrorSession.acceptOffer(offerText)
        mirrorSession = session
        fullscreenStrategy = .window
        prepareWindow(content: NativeMirrorWindowView(session: session))

        watchTask = Task {
            await self.presentAndWatchMirror(session: session)
        }

        return answerSDP
    }

    // Drives the currently playing video's <video> element directly, rather
    // than dispatching synthetic KeyboardEvents at the page: those aren't
    // isTrusted, and a provider's own keyboard-shortcut handling isn't
    // guaranteed to react to them. The actual JS run is up to whichever
    // VideoParser claimed this session, since not every provider's page
    // behaves identically. Restricted to the parsed-video (.element)
    // strategy — the mirror path's remote video has no meaningful play/
    // pause/seek semantics.
    func sendControl(_ control: PlaybackControl) async -> Bool {
        guard case .element = fullscreenStrategy, let page, let activeParser else { return false }
        return await Self.applyControl(control, using: activeParser, to: page)
    }

    // Ends the active video session the same way a natural video-end does:
    // same fullscreen-exit + window-close sequence.
    // Restricted to the parsed-video (.element) strategy, matching sendControl.
    @discardableResult
    func stop() async -> Bool {
        guard case .element = fullscreenStrategy, page != nil, let window else { return false }
        watchTask?.cancel()
        watchTask = nil
        await finishSession(window: window)
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
        if let window {
            await exitFullscreenAndClose(window: window)
        }
        window = nil
        page = nil
        mirrorSession = nil
        activeParser = nil
        releaseDisplayAssertion()
    }

    // Parsed-video sessions only: the window is already shown by the time
    // this runs (see startVideo), so there's nothing left to gate on
    // readiness except the fullscreen request itself, which silently no-ops
    // if the <video> element isn't there yet or hasn't started playing.
    // watchScript() (registered below, before load) pushes a `playing`
    // event once that's no longer true, and an `ended` event when playback
    // finishes — both via BrowserPage's message-handler bridge, instead of
    // Swift polling document state on a timer (see presentAndWatchMirror
    // below for the mirror-path equivalent, driven by NativeMirrorSession's
    // AsyncStreams instead).
    private func presentAndWatch(page: BrowserPage, parser: VideoParser, url: URL) async {
        let playingEvents = page.messages(named: VideoWatchEvent.playingMessageName)
        let endedEvents = page.messages(named: VideoWatchEvent.endedMessageName)
        page.addUserScript(parser.watchScript())
        await page.load(URLRequest(url: url))
        guard !Task.isCancelled else { return }

        // Best-effort: attempt fullscreen once playback starts, but don't
        // block the session on it if that signal never arrives (consent
        // dialogs, slow networks, providers that never fire `playing`).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in playingEvents { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }

        await Self.enterVideoFullscreen(page)

        for await _ in endedEvents { break }
        guard !Task.isCancelled else { return }

        watchTask = nil
        await finishCurrentSession()
    }

    // Mirror-path equivalent of presentAndWatch, driven by
    // NativeMirrorSession pushing events on the actual readiness/disconnect
    // signals instead of Swift polling connection state on a timer. Unlike
    // the video path, the window here is deliberately held back (alpha 0,
    // see prepareWindow) until the Sender's actually ready — there's no
    // in-progress page load worth showing for screen mirroring the way
    // there is for video, just a blank window until content arrives.
    private func presentAndWatchMirror(session: NativeMirrorSession) async {
        // Best-effort readiness wait, matching presentAndWatch's timeout:
        // proceed to show the window even if this times out, rather than
        // never showing anything for a Sender that's stuck.
        // Captured locally before the task group: session.readyEvents is a
        // @MainActor-isolated property, and addTask's child closure isn't
        // MainActor-isolated just by virtue of being created here — the
        // AsyncStream value itself (Sendable) is fine to capture directly.
        let readyEvents = session.readyEvents
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in readyEvents { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }

        reveal()
        if let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        armCursorAutoHide()

        for await _ in session.disconnectedEvents { break }
        guard !Task.isCancelled else { return }

        watchTask = nil
        await finishCurrentSession()
    }

    private static func enterVideoFullscreen(_ page: BrowserPage) async {
        // Give the player UI a moment to settle before requesting fullscreen.
        try? await Task.sleep(for: .milliseconds(700))
        await requestFullscreen(page)
        // If that didn't take (e.g. the player wasn't quite ready), try once more.
        try? await Task.sleep(for: .milliseconds(1200))
        if await !isElementFullscreen(page) {
            await requestFullscreen(page)
        }
    }

    private func finishCurrentSession() async {
        if let window {
            await finishSession(window: window)
        } else {
            page = nil
            mirrorSession = nil
        }
    }

    // Shared by presentAndWatch/presentAndWatchMirror's natural-end path and
    // stop(): tears down the window the same way regardless of what
    // triggered the end.
    private func finishSession(window: NSWindow) async {
        await exitFullscreenAndClose(window: window)
        self.window = nil
        page = nil
        mirrorSession = nil
        releaseDisplayAssertion()
    }

    // Creates and attaches the window's content view immediately, before
    // it's ready, but invisible (alpha 0) until reveal(). This matters, not
    // just cosmetics: for the video-by-URL path, WKWebView's element-
    // fullscreen capability is fixed by its configuration at the time the
    // document loads, so a WebView attached only after the video is already
    // playing is too late — requestFullscreen() silently no-ops on it. The
    // window still needs to be ordered onto screen for SwiftUI to actually
    // realize the content view, not just construct it — alpha 0 (rather
    // than an off-screen position) keeps it invisible even though AppKit
    // auto-repositions new windows that would otherwise be entirely
    // off-screen back into view.
    private func prepareWindow(content: some View) {
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.title = "Abaft"
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
            "Abaft starting playback" as CFString,
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
            "Abaft mirroring/playback" as CFString,
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

    // MARK: - Shared JS predicates
    //
    // These assume a standard HTML5 <video> element, same as VideoParser's
    // default control scripts — see that type for the rationale. Used by
    // parsed-video sessions only; the mirror path has no JS/WebView at all
    // now, and gets its readiness/disconnect signals pushed from
    // NativeMirrorSession instead (see presentAndWatchMirror).

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

    // Which JS actually runs is provider-dependent — delegated to whichever
    // VideoParser claimed this session (see that type for the default HTML5
    // <video> implementation most providers can just inherit).
    private static func applyControl(_ control: PlaybackControl, using parser: VideoParser, to page: BrowserPage) async -> Bool {
        let js: String
        switch control {
        case .playPause: js = parser.playPauseScript()
        case .seekBack: js = parser.seekBackScript()
        case .seekForward: js = parser.seekForwardScript()
        }
        let result = try? await page.callJavaScript(js)
        return (result as? Bool) ?? false
    }

    private func exitFullscreenAndClose(window: NSWindow) async {
        switch fullscreenStrategy {
        case .element:
            if let page {
                _ = try? await page.callJavaScript("""
                    if (document.fullscreenElement) { await document.exitFullscreen(); }
                    """)
            }
            // Give the native fullscreen-exit transition a moment to finish
            // before tearing down the window/space it's animating out of.
            try? await Task.sleep(for: .milliseconds(400))
            window.close()
        case .window:
            // Closes the RTCPeerConnection before the window goes away, so
            // the Projector sees a clean DTLS close rather than having to
            // wait out an ICE consent-timeout to notice the session ended.
            mirrorSession?.teardown()
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
    // never sets document.fullscreenElement — there's no document at all —
    // so WebKit's own idle-hide-cursor behavior for fullscreen video never
    // applies here regardless. Reproduce it natively instead: hide the
    // cursor immediately, then re-hide it after each period of no movement,
    // matching a native fullscreen video player.
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
