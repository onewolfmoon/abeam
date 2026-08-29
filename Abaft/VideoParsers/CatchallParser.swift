import Foundation

/// A parser that matches any URL, for services with no dedicated parser.
struct CatchallParser: VideoParser {
    let identifier = "catchall"

    func parse(_ payload: String) -> URL? {
        firstURL(in: payload)
    }

    func fullscreenScript() -> String {
        "await document.documentElement.requestFullscreen();"
    }

    func watchScript() -> String {
        "window.webkit.messageHandlers.\(VideoWatchEvent.playingMessageName).postMessage('');"
    }
}
