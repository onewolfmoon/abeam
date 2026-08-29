import Foundation

/// A parser that inspects a URL or a share payload. A parser determines whether
/// it recognizes the service. It also provides playback controls.
protocol VideoParser: Sendable {
    nonisolated var identifier: String { get }

    /// The streaming service's human-readable name, e.g. "YouTube". Used as
    /// the title of the window that plays back its content.
    nonisolated var displayName: String { get }

    nonisolated func parse(_ payload: String) -> URL?

    nonisolated func playPauseScript() -> String
    nonisolated func seekBackScript() -> String
    nonisolated func seekForwardScript() -> String
    nonisolated func watchScript() -> String
}

// Message-handler channel names shared between VideoParser's default
// watchScript() and SessionCoordinator.
enum VideoWatchEvent {
    static let playingMessageName = "abaftVideoPlaying"
    static let endedMessageName = "abaftVideoEnded"
}

extension VideoParser {
    nonisolated func playPauseScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        if (v.paused) { v.play(); } else { v.pause(); }
        return true;
        """
    }

    /// Provides a script to seek back 5 seconds. This matches left and right
    /// arrow on YouTube.
    nonisolated func seekBackScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        v.currentTime = Math.max(0, v.currentTime - 5);
        return true;
        """
    }

    /// Provides a script to seek forward 10 seconds. This matches left and
    /// right arrow on YouTube.
    nonisolated func seekForwardScript() -> String {
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
    nonisolated func watchScript() -> String {
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
    nonisolated func firstURL(in payload: String) -> URL? {
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
