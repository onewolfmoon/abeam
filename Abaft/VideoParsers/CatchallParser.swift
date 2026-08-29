import Foundation

/// A parser that matches any URL, for services with no dedicated parser.
struct CatchallParser: VideoParser {
    let identifier = "catchall"

    func parse(_ payload: String) -> URL? {
        firstURL(in: payload)
    }
}
