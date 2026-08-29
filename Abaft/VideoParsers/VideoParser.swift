import Foundation
import SignalingCore
import os

/// A parser that inspects a URL or a share payload. A parser determines whether
/// it recognizes the service. It also provides playback controls.
protocol VideoParser: Sendable {
    var identifier: String { get }

    /// The streaming service's human-readable name, e.g. "YouTube". Used as
    /// the title of the window that plays back its content.
    var displayName: String { get }

    func parse(_ payload: String) -> URL?

    func playPauseScript() -> String
    func seekBackScript() -> String
    func seekForwardScript() -> String
    func watchScript() -> String

    /// Whether `watchScript()` needs to run only in the top-level document
    /// rather than in every frame of the page. Disable this if the video
    /// plays in an iframe that the top-level document doesn't have
    /// permission to attach event listeners to.
    var watchesMainFrameOnly: Bool { get }

    /// Makes a best-effort attempt to put this parser's player into
    /// fullscreen.
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
    var watchesMainFrameOnly: Bool { true }

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

    /// Makes a best-effort attempt to go full screen. The following are
    /// attempted in order in injected JavaScript.
    ///
    /// 1. Simulates pressing `f` on the keyboard
    /// 2. Requests full screen on the `video` element
    @MainActor
    func enterFullscreen(page: BrowserPage) async {
        await attemptFullscreen(
            page: page,
            service: identifier,
            // Give the player UI a moment to settle before requesting
            // fullscreen.
            initialDelay: .milliseconds(700),
            firstAttempt: { await simulateFullscreenKeypress(page) },
            firstDelay: .milliseconds(500),
            retryAttempt: { await requestFullscreenOnVideoElement(page) },
            retryDelay: .milliseconds(1200)
        )
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

// MARK: - Fullscreen instrumentation

let fullscreenLogger = Logger(subsystem: "dev.wolfmoon.Abaft", category: "fullscreen")

/// Runs a two-attempt fullscreen strategy shared by every parser: wait for
/// the player to settle, try once, wait and check; if that didn't work, try
/// again, wait and check. Only what a single "attempt" does (`firstAttempt`/
/// `retryAttempt`) differs per parser -- this shared shape is what makes it
/// possible to log a consistent success/attempts/elapsed-time outcome for
/// every service, whatever its underlying mechanism.
@MainActor
func attemptFullscreen(
    page: BrowserPage,
    service: String,
    initialDelay: Duration,
    firstAttempt: () async -> Void,
    firstDelay: Duration,
    retryAttempt: () async -> Void,
    retryDelay: Duration
) async {
    let start = Date()
    try? await Task.sleep(for: initialDelay)

    // Something outside this function (e.g. a parser's own injected script,
    // acting independently of this Swift-side attempt) may have already
    // succeeded by now. Check before acting: firstAttempt's action might be
    // a toggle (like a keypress), and sending one unconditionally would
    // silently undo an already-successful fullscreen entry.
    if await isElementFullscreen(page) {
        logFullscreenOutcome(service: service, succeeded: true, attempts: 0, since: start)
        return
    }

    await firstAttempt()
    if await waitForFullscreen(page: page, timeout: firstDelay) {
        logFullscreenOutcome(service: service, succeeded: true, attempts: 1, since: start)
        return
    }

    // Attempt retry once `waitForFullscreen` has finished unsuccessfully.
    // Retrying sends the same action again (e.g. another "f" keypress),
    // which for a toggle-based strategy would silently undo a first
    // attempt that actually succeeded just a little late, if we retried on
    // a false negative here.
    fullscreenLogger.debug("\(service, privacy: .public): first attempt didn't land, retrying")
    await retryAttempt()
    let succeeded = await waitForFullscreen(page: page, timeout: retryDelay)
    logFullscreenOutcome(service: service, succeeded: succeeded, attempts: 2, since: start)
}

/// Polls fullscreen state instead of taking one snapshot after a fixed
/// delay, returning as soon as fullscreen is detected. A single
/// point-in-time check after a sleep is prone to false negatives if the
/// site's own fullscreen transition hasn't updated
/// `document.fullscreenElement` by that exact moment. A false negative is
/// worse than a slow true positive, since it can be followed by a
/// same-action retry that can undo a toggle-based attempt that actually
/// worked.
@MainActor
private func waitForFullscreen(
    page: BrowserPage,
    timeout: Duration,
    pollInterval: Duration = .milliseconds(100)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await isElementFullscreen(page) { return true }
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: pollInterval)
    }
}

private func logFullscreenOutcome(service: String, succeeded: Bool, attempts: Int, since start: Date) {
    let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
    if succeeded, attempts == 0 {
        fullscreenLogger.info(
            "\(service, privacy: .public): already fullscreen after \(elapsedMS, privacy: .public)ms, no attempt needed"
        )
    } else if succeeded {
        fullscreenLogger.info(
            "\(service, privacy: .public): entered fullscreen in \(elapsedMS, privacy: .public)ms (attempt \(attempts, privacy: .public)/2)"
        )
    } else {
        fullscreenLogger.error(
            "\(service, privacy: .public): failed to enter fullscreen after \(elapsedMS, privacy: .public)ms and \(attempts, privacy: .public)/2 attempts"
        )
    }
}

// MARK: - Shared JS predicates
//
// These assume a standard HTML5 `video` element living in the same document
// the script runs in.

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
