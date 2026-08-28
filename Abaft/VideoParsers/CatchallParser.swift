import Foundation

/// A parser that matches any HTTP/HTTPS URL, for services with no dedicated
/// parser. Unlike a service-specific parser, this one doesn't assume the
/// page has a `<video>` element to control, so it's shown as a full-screen
/// web page rather than full-screen video.
///
/// Keep this last in `VideoParserRegistry.default` so specific parsers get
/// the first chance to recognize a URL.
struct CatchallParser: VideoParser {
    let identifier = "catchall"

    var presentation: VideoPresentation { .fullPage }

    func parse(_ payload: String) -> URL? {
        firstURL(in: payload)
    }
}
