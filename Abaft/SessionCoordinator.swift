import AppKit
import IOKit.pwr_mgt
import SignalingCore
import SwiftUI
import VideoParsers

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

/// Owner of the current session. A session can be playback of a video in a web
/// view or screen mirroring.
///
/// All mutable state is isolated to MainActor. Sendable allows
/// ReceiverSocketServer to store this session as a property and call it across
/// the actor boundary.
@MainActor
final class SessionCoordinator: Sendable {
    enum PlaybackControl {
        case playPause
        case seekBack
        case seekForward
    }

    /// How the session is displayed.
    private enum FullscreenStrategy {
        /// The session is video playback displayed in a web view.
        case element
        /// The session is screen mirroring displayed in a native window.
        case window
    }

    private var watchTask: Task<Void, Never>?
    private var window: NSWindow?
    private var page: BrowserPage?
    private var mirrorSession: NativeMirrorSession?
    private var activeParser: VideoParser?
    private var fullscreenStrategy: FullscreenStrategy = .element
    // nonisolated(unsafe): Timer/the monitor token aren't Sendable-exempt the
    // way AppKit's own @MainActor types (e.g. NSWindow above) are, which would
    // otherwise break this class's Sendable conformance. Safe here since both
    // are only ever touched from this MainActor-isolated class.

    // TODO: Understand why this is and whether there's a better option.
    private nonisolated(unsafe) var cursorMoveMonitor: Any?
    private nonisolated(unsafe) var cursorHideTimer: Timer?
    private var displayAssertionID: IOPMAssertionID?

    /// Starts playing the video represented in the payload.
    /// - Parameter payload: The share payload or user-entered string containing
    /// the address of the video to play.
    /// - Returns: `true` if the video was parseable, and `false` otherwise.
    @discardableResult
    func startVideo(payload: String) async -> Bool {
        guard let (url, parser) = VideoParserRegistry.default.parse(payload)
        else { return false }

        await teardownCurrentSession()

        let page = BrowserPage()
        self.page = page
        activeParser = parser
        fullscreenStrategy = .element
        prepareWindow(
            content: SessionWindowView(page: page),
            title: parser.displayName
        )
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

    /// Proxies the SDP exchange to NativeMirrorSession.
    @discardableResult
    func startOffer(_ offerText: String) async throws -> String {
        await teardownCurrentSession()

        let (session, answerSDP) = try await NativeMirrorSession.acceptOffer(
            offerText
        )
        mirrorSession = session
        fullscreenStrategy = .window
        prepareWindow(content: NativeMirrorWindowView(session: session))

        watchTask = Task {
            await self.presentAndWatchMirror(session: session)
        }

        return answerSDP
    }

    /// Controls the video element in the web view.
    ///
    /// This method does nothing if nothing's playing or screen mirroring is
    /// active.
    func sendControl(_ control: PlaybackControl) async -> Bool {
        guard case .element = fullscreenStrategy, let page, let activeParser
        else { return false }
        return await Self.applyControl(control, using: activeParser, to: page)
    }

    /// Turns on the display, independent of any active session.
    func turnDisplayOn() {
        Self.wakeDisplay()
    }

    /// Stops any active session and turns off the display.
    func turnDisplayOff() async {
        await stop()
        Self.sleepDisplay()
    }

    /// Ends the current session.
    ///
    /// This method does nothing if no video is playing and screen mirroring
    /// is not active.
    @discardableResult
    func stop() async -> Bool {
        guard let window else { return false }
        switch fullscreenStrategy {
        case .element:
            guard page != nil else { return false }
        case .window:
            guard mirrorSession != nil else { return false }
        }
        watchTask?.cancel()
        watchTask = nil
        await finishSession(window: window)
        return true
    }

    // MARK: - Session lifecycle

    private func teardownCurrentSession() async {
        watchTask?.cancel()
        watchTask = nil
        if let window {
            // Exiting full screen mode is necessary to make the next window
            // more likely to open and appear.
            await exitFullscreenAndClose(window: window)
        }
        window = nil
        page = nil
        mirrorSession = nil
        activeParser = nil
        releaseDisplayAssertion()
    }

    /// Injects scripts to interact with the video lifecycle.
    ///
    /// Call this after the window has already been shown with `startVideo`.
    private func presentAndWatch(
        page: BrowserPage,
        parser: VideoParser,
        url: URL
    ) async {
        let playingEvents = page.messages(
            named: VideoWatchEvent.playingMessageName
        )
        let endedEvents = page.messages(named: VideoWatchEvent.endedMessageName)
        page.addUserScript(parser.watchScript(), forMainFrameOnly: parser.watchesMainFrameOnly)
        await page.load(URLRequest(url: url))
        guard !Task.isCancelled else { return }

        // Make a best-effort attempt to go full screen once playback starts.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in playingEvents { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }

        await parser.enterFullscreen(page: page)

        for await _ in endedEvents { break }
        guard !Task.isCancelled else { return }

        watchTask = nil
        await finishCurrentSession()
    }

    /// Presents the screen mirroring window and handles its lifecycle.
    private func presentAndWatchMirror(session: NativeMirrorSession) async {
        // Wait for mirroring to be ready.

        // TODO: Understand this.
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

    private func finishCurrentSession() async {
        if let window {
            await finishSession(window: window)
        } else {
            page = nil
            mirrorSession = nil
        }
    }

    /// Handles the end of a screen mirroring session or video playback session.
    private func finishSession(window: NSWindow) async {
        await exitFullscreenAndClose(window: window)
        self.window = nil
        page = nil
        mirrorSession = nil
        releaseDisplayAssertion()
    }

    /// Creates and attaches the window's content view.
    private func prepareWindow(content: some View, title: String = "Abeam Receiver") {
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.title = title
        // Start with the window transparent. This gives the web view a moment
        // to load; otherwise, going full screen fails.
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

    /// Wakes the display.
    ///
    /// This does not keep the display awake. Use in combination with
    /// `acquireDisplayAssertion`.
    private static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "Abeam Receiver starting playback" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }

    /// Puts the display to sleep immediately.
    private static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// Keeps the display awake.
    ///
    /// This does not wake the display. Use in combination with `wakeDisplay`.
    private func acquireDisplayAssertion() {
        guard displayAssertionID == nil else { return }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Abeam Receiver mirroring/playback" as CFString,
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

    /// The scripts that are injected to the video page. These scripts are
    /// specific to each streaming service and so are provided by the
    /// service-specific parsers.
    private static func applyControl(
        _ control: PlaybackControl,
        using parser: VideoParser,
        to page: BrowserPage
    ) async -> Bool {
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
                _ = try? await page.callJavaScript(
                    """
                    if (document.fullscreenElement) { await document.exitFullscreen(); }
                    """
                )
            }
            // TODO: Is there a better way to both exit full screen and close
            // the window?

            // Wait for the un-fullscreen transition to finish before tearing
            // down the window.
            try? await Task.sleep(for: .milliseconds(400))
            window.close()
        case .window:
            // Close the WebRTC connection to signal to Abeam that the session
            // is over.
            mirrorSession?.teardown()
            disarmCursorAutoHide()
            window.close()
        }
    }

    /// Hides the cursor and rehides it after movement.
    private func armCursorAutoHide() {
        window?.acceptsMouseMovedEvents = true
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved
        ]) { [weak self] event in
            self?.scheduleCursorHide()
            return event
        }
    }

    private func scheduleCursorHide() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(
            withTimeInterval: 2.5,
            repeats: false
        ) { _ in
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
