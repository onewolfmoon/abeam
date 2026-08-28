import Foundation

/// A parser that inspects a URL or a share payload. A parser determines whether
/// it recognizes the service. It also provides playback controls.
protocol VideoParser: Sendable {
    var identifier: String { get }

    /// How the matched URL should be presented once loaded.
    var presentation: VideoPresentation { get }

    func parse(_ payload: String) -> URL?

    func playPauseScript() -> String
    func seekBackScript() -> String
    func seekForwardScript() -> String
    func watchScript() -> String
}

/// How a parser's matched page should be shown full screen.
enum VideoPresentation: Sendable, Equatable {
    /// Full-screen the page's `<video>` element. Used by parsers for
    /// services known to play video, so playback controls and end-of-video
    /// detection apply.
    case videoElement
    /// Full-screen the whole page. Used when the page's contents, and
    /// whether it even contains a `<video>` element, aren't known ahead of
    /// time.
    case fullPage
}

// Message-handler channel names shared between VideoParser's default
// watchScript() and SessionCoordinator.
enum VideoWatchEvent {
    static let playingMessageName = "abaftVideoPlaying"
    static let endedMessageName = "abaftVideoEnded"
}

extension VideoParser {
    var presentation: VideoPresentation { .videoElement }

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

/// The parsers in the order they will be tried.
struct VideoParserRegistry: Sendable {
    let parsers: [VideoParser]

    static let `default` = VideoParserRegistry(parsers: [
        YouTubeParser(),
        DropoutParser(),
        // Must stay last: it matches any HTTP/HTTPS URL, so it would
        // otherwise shadow every parser after it.
        CatchallParser(),
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
