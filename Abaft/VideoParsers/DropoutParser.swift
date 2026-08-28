import AppKit
import Foundation
import SignalingCore
import WebKit
import os

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

    /// Dropout's `<video>` lives inside a cross-origin iframe, invisible to
    /// a script running in the top document -- so this needs to run in
    /// every frame instead of just the main frame (see `watchScript()`).
    var watchesAllFrames: Bool { true }

    /// The default `watchScript()` waits for a `<video>` `playing` event to
    /// signal `SessionCoordinator` that it's safe to attempt fullscreen, and
    /// separately watches for `ended` to close the session -- both by
    /// looking for a `<video>` in the document the script runs in. Injected
    /// into every frame (via `watchesAllFrames`), this script runs both in
    /// the top document, where there's no `<video>` to find, and inside
    /// Dropout's video iframe, where there is one -- `window === window.top`
    /// tells the two apart:
    ///
    /// - Top document: report "playing" immediately rather than waiting on
    ///   a signal that can never arrive there. That signal has exactly one
    ///   consumer -- SessionCoordinator's "wait for playing, or give up
    ///   after 25s" race before calling `enterFullscreen` -- and
    ///   `enterFullscreen` already has its own settle delay and
    ///   retry-tolerant polling, so there's nothing to lose by reporting
    ///   "playing" immediately.
    /// - Every other frame: same `<video>`-watching logic the default
    ///   implementation uses, which now actually finds the real element
    ///   since it's running inside the iframe's own document. Only watches
    ///   for `ended` here -- "playing" is already handled above.
    ///
    /// Caveat: this also runs inside any other iframe on the page (ads,
    /// trackers, etc). If one of those happens to embed its own `<video>`,
    /// this would attach to that instead and could fire a false "ended"
    /// when the ad finishes rather than the real content. Not something we
    /// can rule out without knowing Dropout's ad-iframe structure; watch
    /// for a Dropout session closing suspiciously early as a symptom.
    func watchScript() -> String {
        """
        if (window === window.top) {
            window.webkit.messageHandlers.\(VideoWatchEvent.playingMessageName).postMessage('');
        } else {
            (function() {
              function attach(v) {
                if (v.__abaftWatchAttached) return;
                v.__abaftWatchAttached = true;
                v.addEventListener('ended', function() {
                  window.webkit.messageHandlers.\(VideoWatchEvent.endedMessageName).postMessage('');
                });
              }
              var existing = document.querySelector('video');
              if (existing) { attach(existing); }
              new MutationObserver(function() {
                var v = document.querySelector('video');
                if (v) { attach(v); }
              }).observe(document.documentElement, { childList: true, subtree: true });
            })();
        }
        """
    }

    /// Dropout's player lives inside a cross-origin iframe (Vimeo OTT/VHX),
    /// confirmed by inspecting a live page: `document.querySelector('video')`
    /// on the top document finds nothing, and the iframe's `contentDocument`
    /// is inaccessible. A JavaScript `dispatchEvent` call can never reach
    /// into that iframe's document -- that's a security boundary, not a
    /// focus issue -- so the shared JS-based default doesn't work here.
    ///
    /// Instead, focus the iframe via `HTMLIFrameElement.focus()` followed
    /// by a real "f" keypress synthesized via AppKit. WebKit's own input
    /// routing delivers genuine platform events to whichever frame
    /// currently has focus, including cross-origin ones, the same way an
    /// actual physical keypress would -- unlike a JS-synthesized DOM event,
    /// which stays confined to the document that dispatched it.
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        func focusAndPressF() async {
            await Self.focusPlayerFrame(page)
            Self.synthesizeKeypress(on: page.webView, character: "f", keyCode: 3)  // kVK_ANSI_F
        }
        await attemptFullscreen(
            page: page,
            service: identifier,
            initialDelay: .milliseconds(700),
            firstAttempt: focusAndPressF,
            firstDelay: .milliseconds(500),
            retryAttempt: focusAndPressF,
            retryDelay: .milliseconds(500)
        )
    }

    /// Moves real browsing-context focus into the video player's iframe,
    /// ahead of sending it a keypress. Uses `HTMLIFrameElement.focus()` on
    /// the outer iframe element from the top document -- legal even though
    /// the iframe is cross-origin, since it's a method on the accessible
    /// frame node itself, not a reach into its content -- rather than a
    /// synthesized click: an earlier version clicked the center of the
    /// iframe to focus it, but that landed on the player's click-to-
    /// toggle-playback overlay instead, silently pausing/resuming playback
    /// without ever actually focusing the frame (confirmed via logging: the
    /// "f" keypress that followed never registered as fullscreen).
    @MainActor
    private static func focusPlayerFrame(_ page: BrowserPage) async {
        let focusStart = Date()
        _ = try? await page.callJavaScript(
            """
            var el = document.getElementById('watch-embed')
                || document.querySelector('iframe[allow*="fullscreen"]');
            if (el) { el.focus(); }
            """
        )
        fullscreenLogger.debug(
            "dropout: iframe focus() took \(Int(Date().timeIntervalSince(focusStart) * 1000), privacy: .public)ms"
        )
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
