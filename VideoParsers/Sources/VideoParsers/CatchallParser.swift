import Foundation
import SignalingCore

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

    /// Requests fullscreen directly, falling back to the whole document
    /// when there's no `<video>` element.
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        await attemptFullscreen(
            page: page,
            service: identifier,
            initialDelay: .milliseconds(700),
            firstAttempt: { await Self.requestFullscreen(page) },
            firstDelay: .milliseconds(500),
            retryAttempt: { await Self.requestFullscreen(page) },
            retryDelay: .milliseconds(1200)
        )
    }

    @MainActor
    private static func requestFullscreen(_ page: BrowserPage) async {
        _ = try? await page.callJavaScript(
            """
            var v = document.querySelector('video') || document.documentElement;
            if (v) { await v.requestFullscreen(); }
            """
        )
    }
}
