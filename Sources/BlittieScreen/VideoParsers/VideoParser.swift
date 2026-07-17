import Foundation

// A VideoParser inspects a raw share payload (whatever text the sending app's
// share sheet handed over — a bare URL, or freeform text with a URL embedded
// in it, e.g. "I'm watching X on Y\nhttps://...") and, if it recognizes the
// video service it came from, returns the URL that should be loaded into the
// player WebView. Returning nil means "not mine" — the registry moves on to
// the next parser.
//
// Playback controls are provider-specific too (a future provider might not
// expose a plain HTML5 <video> element), so each parser also owns the JS run
// for play/pause/seek. The default implementations below cover any provider
// whose page renders a standard <video> element — true of YouTube's watch
// page and (per Dropout's likely player) Dropout too — so most parsers won't
// need to override anything beyond `parse`.
protocol VideoParser: Sendable {
    var identifier: String { get }

    func parse(_ payload: String) -> URL?

    func playPauseScript() -> String
    func seekBackScript() -> String
    func seekForwardScript() -> String
}

extension VideoParser {
    // 5 seconds matches YouTube's own left/right arrow-key shortcut, so the
    // remote buttons feel like the real thing.
    func playPauseScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        if (v.paused) { v.play(); } else { v.pause(); }
        return true;
        """
    }

    func seekBackScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        v.currentTime = Math.max(0, v.currentTime - 5);
        return true;
        """
    }

    func seekForwardScript() -> String {
        """
        var v = document.querySelector('video');
        if (!v) return false;
        v.currentTime = Math.min(v.duration || Infinity, v.currentTime + 5);
        return true;
        """
    }

    // Shared by parsers that just need "the first http(s) URL anywhere in
    // this text" before applying their own host check.
    func firstURL(in payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let scheme = url.scheme, scheme.hasPrefix("http") {
                return url
            }
        }
        return nil
    }
}

// Tries each registered parser in order; the first one that claims the
// payload wins. If more than one parser could claim the same URL, whichever
// is registered first wins — arbitrary but deterministic.
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
