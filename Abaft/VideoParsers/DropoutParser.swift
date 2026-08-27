import AppKit
import Foundation
import SignalingCore
import WebKit

/// A parser that parses share payloads from Dropout.
///
/// > I'm watching Count the Rice on Dropout
/// >
/// > http://watch.dropout.tv/videos/count-the-rice
///
/// This parser also replaces the `http` scheme with `https`, as App Transport
/// Security disallows insecure network connections over the internet.
struct DropoutParser: VideoParser {
    let identifier = "dropout"

    func parse(_ payload: String) -> URL? {
        guard let url = firstURL(in: payload), let host = url.host?.lowercased()
        else { return nil }
        guard host == "dropout.tv" || host.hasSuffix(".dropout.tv") else {
            return nil
        }

        guard url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    /// Dropout's player lives inside a cross-origin iframe (Vimeo OTT/VHX),
    /// confirmed by inspecting a live page: `document.querySelector('video')`
    /// on the top document finds nothing, and the iframe's `contentDocument`
    /// is inaccessible. A JavaScript `dispatchEvent` call can never reach
    /// into that iframe's document -- that's a security boundary, not a
    /// focus issue -- so the shared JS-based default doesn't work here.
    ///
    /// Instead, synthesize a real AppKit mouse click on the iframe (to give
    /// it focus) followed by a real "f" keypress. WebKit's own input
    /// routing delivers genuine platform events to whichever frame
    /// currently has focus, including cross-origin ones, the same way an
    /// actual physical keypress would -- unlike a JS-synthesized DOM event,
    /// which stays confined to the document that dispatched it.
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        try? await Task.sleep(for: .milliseconds(700))

        await Self.focusPlayerFrame(page)
        Self.synthesizeKeypress(on: page.webView, character: "f", keyCode: 3)  // kVK_ANSI_F
        try? await Task.sleep(for: .milliseconds(500))

        if await !isElementFullscreen(page) {
            // Single retry -- the click may not have landed the first time.
            await Self.focusPlayerFrame(page)
            Self.synthesizeKeypress(on: page.webView, character: "f", keyCode: 3)
        }
    }

    /// Clicks the center of the video player's iframe so WebKit's internal
    /// page focus moves into it, ahead of sending it a keypress.
    @MainActor
    private static func focusPlayerFrame(_ page: BrowserPage) async {
        guard
            let center = try? await page.callJavaScript(
                """
                var el = document.getElementById('watch-embed')
                    || document.querySelector('iframe[allow*="fullscreen"]');
                if (!el) return null;
                var r = el.getBoundingClientRect();
                return [r.x + r.width / 2, r.y + r.height / 2];
                """
            ) as? [Double],
            center.count == 2
        else { return }

        let webView = page.webView
        // getBoundingClientRect() is in CSS pixels, top-left origin, y
        // increasing downward; flip into AppKit view space if the web view
        // isn't itself a flipped view.
        let viewPoint =
            webView.isFlipped
            ? NSPoint(x: center[0], y: center[1])
            : NSPoint(x: center[0], y: webView.bounds.height - center[1])
        synthesizeClick(on: webView, at: viewPoint)
    }

    @MainActor
    private static func synthesizeClick(on webView: WKWebView, at viewPoint: NSPoint) {
        guard let window = webView.window else { return }
        let windowPoint = webView.convert(viewPoint, to: nil)
        postMouseEvent(.leftMouseDown, window: window, location: windowPoint)
        postMouseEvent(.leftMouseUp, window: window, location: windowPoint)
    }

    @MainActor
    private static func synthesizeKeypress(
        on webView: WKWebView,
        character: String,
        keyCode: UInt16
    ) {
        guard let window = webView.window else { return }
        postKeyEvent(.keyDown, window: window, character: character, keyCode: keyCode)
        postKeyEvent(.keyUp, window: window, character: character, keyCode: keyCode)
    }

    @MainActor
    private static func postMouseEvent(
        _ type: NSEvent.EventType,
        window: NSWindow,
        location: NSPoint
    ) {
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
        else { return }
        window.sendEvent(event)
    }

    @MainActor
    private static func postKeyEvent(
        _ type: NSEvent.EventType,
        window: NSWindow,
        character: String,
        keyCode: UInt16
    ) {
        guard
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: keyCode
            )
        else { return }
        window.sendEvent(event)
    }
}
