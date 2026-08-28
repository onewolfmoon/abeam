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

    /// Specifies that video events are listened for in all frames in the
    /// page. Dropout's video element lives in a cross-origin iframe, so a
    /// script running in the main document can't attach event listeners to
    /// the video element due to same-origin policy.
    var watchesAllFrames: Bool { true }

    /// This method returns the script that listens for video playback
    /// events.
    ///
    /// The script running in the top-level document reports that playing
    /// starts immediately, since the top-level document can't observe when
    /// video playback actually starts.
    ///
    /// TODO: More robustly detect the start of video playback.
    ///
    /// The script also runs in every other frame and watches for the video
    /// ending. This may misbehave if more than one frame contains a
    /// playing video.
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

    /// Uses AppKit to dispatch an "f" keypress to a video player that
    /// rejects synthetic JavaScript events.
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        func focusAndPressF() async {
            await Self.focusPlayerFrame(page)
            Self.synthesizeKeypress(on: page.webView, character: "f", keyCode: 3)  // kVK_ANSI_F
        }
        // TODO: retryAttempt uses the same toggle action as firstAttempt,
        // which could undo a slow-to-register success. Hasn't happened in
        // manual testing, but consider a more robust verification.
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

    /// Focuses the iframe containing the video player
    /// ahead of sending it a keypress. Uses `HTMLIFrameElement.focus()` on
    /// the outer iframe element from the top document.
    @MainActor
    private static func focusPlayerFrame(_ page: BrowserPage) async {
        let focusStart = Date()
        _ = try? await page.callJavaScript(
            """
            var el = document.getElementById('watch-embed');
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
