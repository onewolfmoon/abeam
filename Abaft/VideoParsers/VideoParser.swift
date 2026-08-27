import Foundation
import SignalingCore

/// A parser that inspects a URL or a share payload. A parser determines whether
/// it recognizes the service. It also provides playback controls.
protocol VideoParser: Sendable {
    var identifier: String { get }

    func parse(_ payload: String) -> URL?

    func playPauseScript() -> String
    func seekBackScript() -> String
    func seekForwardScript() -> String
    func watchScript() -> String

    /// Makes a best-effort attempt to put this parser's player into
    /// fullscreen. How to do that varies by service -- e.g. whether the
    /// player is a same-document `<video>` element or lives inside a
    /// cross-origin iframe -- so each parser can provide its own strategy.
    @MainActor
    func enterFullscreen(page: BrowserPage) async
}

// Message-handler channel names shared between VideoParser's default
// watchScript() and SessionCoordinator.
enum VideoWatchEvent {
    static let playingMessageName = "abaftVideoPlaying"
    static let endedMessageName = "abaftVideoEnded"
}

extension VideoParser {
    func playPauseScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        if (v.paused) { v.play(); } else { v.pause(); }
        return true;
        """
    }

    /// Provides a script to seek back 5 seconds. This matches left and right
    /// arrow on YouTube.
    func seekBackScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        v.currentTime = Math.max(0, v.currentTime - 5);
        return true;
        """
    }

    /// Provides a script to seek forward 10 seconds. This matches left and
    /// right arrow on YouTube.
    func seekForwardScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        v.currentTime = Math.min(v.duration || Infinity, v.currentTime + 5);
        return true;
        """
    }

    /// Provides a script that registers video start and end events. These are
    /// safe to inject at page load; the MutationObserver will register the
    /// events once that's possible.
    func watchScript() -> String {
        """
        (function() {
          function attach(v) {
            if (v.__abaftWatchAttached) return;
            v.__abaftWatchAttached = true;
            v.addEventListener('playing', function() {
              window.webkit.messageHandlers.\(VideoWatchEvent.playingMessageName).postMessage('');
            });
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
        """
    }

    /// Makes a best-effort attempt to put this parser's player into
    /// fullscreen by simulating the "f" keyboard shortcut most HTML5 video
    /// players bind to fullscreen, so the site's own handler runs -- it
    /// usually does more than a bare requestFullscreen() call (may
    /// fullscreen a wrapper element instead of the raw <video>, reset
    /// sizing, reposition its own overlay UI). Falls back to requesting
    /// fullscreen on the <video> element directly if the site doesn't
    /// respond to "f".
    ///
    /// This default only works when the player lives in the same document
    /// the JavaScript runs in -- a synthetic DOM event dispatched here can
    /// never reach into a cross-origin iframe. Parsers whose player is
    /// embedded that way (e.g. Dropout) need to override this.
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        // TODO: There must be something more elegant than hardcoded delays.

        // Give the player UI a moment to settle before requesting fullscreen.
        try? await Task.sleep(for: .milliseconds(700))

        await simulateFullscreenKeypress(page)
        try? await Task.sleep(for: .milliseconds(500))
        if await !isElementFullscreen(page) {
            await requestFullscreenOnVideoElement(page)
            // Single retry.
            try? await Task.sleep(for: .milliseconds(1200))
            if await !isElementFullscreen(page) {
                await requestFullscreenOnVideoElement(page)
            }
        }
    }

    /// Returns the first HTTP/HTTPS URL in the payload. This method first tries
    /// to find the URL directly, then defers to a data detector.
    func firstURL(in payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            )
        else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let scheme = url.scheme,
                scheme.hasPrefix("http")
            {
                return url
            }
        }
        return nil
    }
}

// MARK: - Shared JS predicates
//
// These assume a standard HTML5 `video` element living in the same document
// the script runs in. Parsers whose player doesn't fit that (e.g. one
// embedded in a cross-origin iframe) need their own strategy instead.

@MainActor
func simulateFullscreenKeypress(_ page: BrowserPage) async {
    _ = try? await page.callJavaScript(
        """
        function dispatchKey(type) {
            var evt = new KeyboardEvent(type, {
                key: 'f', code: 'KeyF', keyCode: 70, which: 70,
                bubbles: true, cancelable: true, composed: true
            });
            (document.activeElement || document.body || document)
                .dispatchEvent(evt);
        }
        dispatchKey('keydown');
        dispatchKey('keyup');
        """
    )
}

@MainActor
func requestFullscreenOnVideoElement(_ page: BrowserPage) async {
    _ = try? await page.callJavaScript(
        """
        var v = document.querySelector('video');
        if (v) { await v.requestFullscreen(); }
        """
    )
}

/// Checks fullscreen state via the top-level document. This also picks up an
/// iframe going fullscreen: the Fullscreen API sets the ancestor document's
/// `fullscreenElement` to the `<iframe>` itself when nested content enters
/// fullscreen, so this works regardless of which parser/strategy is used.
@MainActor
func isElementFullscreen(_ page: BrowserPage) async -> Bool {
    let result = try? await page.callJavaScript(
        "return !!document.fullscreenElement;"
    )
    return (result as? Bool) ?? false
}

/// The parsers in the order they will be tried.
struct VideoParserRegistry: Sendable {
    let parsers: [VideoParser]

    static let `default` = VideoParserRegistry(parsers: [
        YouTubeParser(),
        DropoutParser(),
    ])

    func parse(_ payload: String) -> (url: URL, parser: VideoParser)? {
        for parser in parsers {
            if let url = parser.parse(payload) {
                return (url, parser)
            }
        }
        return nil
    }
}
