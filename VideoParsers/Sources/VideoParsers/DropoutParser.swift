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
    let displayName = "Dropout"

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
    /// page rather than just the top-level document. Dropout's video
    /// element lives in a cross-origin iframe, so a script running in the
    /// main document can't attach event listeners to the video element due
    /// to same-origin policy.
    var watchesMainFrameOnly: Bool { false }

    /// Returns the script that listens for video playback events.
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
    ///
    /// Every frame also listens for `postMessage` control commands and
    /// applies them to a local `<video>` element, or relays them further
    /// down into any child iframes if it doesn't have one.
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
        (function() {
          window.addEventListener('message', function(e) {
            // Only accept commands relayed down from this frame's own
            // parent. e.source is a live reference to the sender's window
            // that page content can't forge.
            if (e.source !== window.parent) return;
            var command = e.data && e.data.\(Self.controlMessageKey);
            if (!command) return;

            var v = document.querySelector('video');
            if (v) {
              abaftApplyControl(command, v);
              return;
            }
            // No local video: the real player may be nested in a further
            // iframe (e.g. Dropout's embed wrapping a Vimeo player). Relay
            // the command down until a frame with a video handles it.
            var frames = document.getElementsByTagName('iframe');
            for (var i = 0; i < frames.length; i++) {
              if (frames[i].contentWindow) {
                frames[i].contentWindow.postMessage(e.data, '*');
              }
            }
          });
        })();
        """
    }

    /// The key used in `postMessage` payloads to carry a control command
    /// into Dropout's cross-origin player iframe.
    private static let controlMessageKey = "abaftControl"

    /// Posts a control command into the player's iframe instead of
    /// manipulating a local `<video>` element directly.
    func playPauseScript() -> String { Self.postControlScript(command: "playPause") }
    func seekBackScript() -> String { Self.postControlScript(command: "seekBack") }
    func seekForwardScript() -> String { Self.postControlScript(command: "seekForward") }

    /// Posts a control command to the player's iframe.
    ///
    /// This can't confirm the command actually reached a video element —
    /// posting a message doesn't wait for a reply — so it optimistically
    /// reports success once the message is sent, the same best-effort
    /// tradeoff `watchScript()` makes for reporting the start of playback.
    private static func postControlScript(command: String) -> String {
        """
        var el = document.getElementById('watch-embed');
        var win = el && (el.contentWindow
            || (el.querySelector && el.querySelector('iframe') && el.querySelector('iframe').contentWindow));
        if (!win) return false;
        win.postMessage({ \(controlMessageKey): '\(command)' }, '*');
        return true;
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
        // TODO: Consider a more robust verification of fullscreen success.
        // retryAttempt uses the same toggle action as firstAttempt, which
        // could undo a slow-to-register success. Hasn't happened in manual
        // testing.
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

    /// Focuses the iframe containing the video player ahead of sending it
    /// a keypress.
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
