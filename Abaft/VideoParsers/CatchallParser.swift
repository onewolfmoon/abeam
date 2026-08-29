import Foundation

/// A parser that matches any URL for services with no dedicated parser.
///
/// Unlike a service-specific parser, this one doesn't assume the page has a
/// `<video>` element to control, so it's shown as a full-screen web page
/// rather than full-screen video.
nonisolated struct CatchallParser: VideoParser {
    let identifier = "catchall"
    let displayName = "Web"

    func parse(_ payload: String) -> URL? {
        firstURL(in: payload)
    }
}
