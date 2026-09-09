import Foundation
import Testing

@testable import VideoParsers

struct DropoutParserTests {

    @Test func parsesDropoutTVHost() throws {
        let parsed = try #require(
            DropoutParser().parse("https://dropout.tv/videos/count-the-rice")
        )
        #expect(parsed.absoluteString == "https://dropout.tv/videos/count-the-rice")
    }

    @Test func parsesSubdomainOfDropoutTV() throws {
        let parsed = try #require(
            DropoutParser().parse("https://watch.dropout.tv/videos/count-the-rice")
        )
        #expect(parsed.host == "watch.dropout.tv")
    }

    @Test func rejectsUnrecognizedHost() {
        #expect(DropoutParser().parse("https://example.com/videos/count-the-rice") == nil)
    }

    @Test func upgradesHTTPSchemeToHTTPS() throws {
        // Documented behavior: App Transport Security disallows insecure
        // connections, so an http:// share link is rewritten to https://.
        let parsed = try #require(
            DropoutParser().parse("http://watch.dropout.tv/videos/count-the-rice")
        )
        #expect(parsed.absoluteString == "https://watch.dropout.tv/videos/count-the-rice")
    }

    @Test func leavesHTTPSSchemeUnchanged() throws {
        let parsed = try #require(
            DropoutParser().parse("https://watch.dropout.tv/videos/count-the-rice")
        )
        #expect(parsed.scheme == "https")
    }

    @Test func watchesEveryFrameRatherThanMainFrameOnly() {
        // Dropout's video element lives in a cross-origin iframe, so the
        // watch script needs to run in every frame, not just the top level.
        #expect(DropoutParser().watchesMainFrameOnly == false)
    }

    // Play/pause/seek can't reach into Dropout's cross-origin player iframe
    // with `document.querySelector('video')` the way the default
    // VideoParser scripts do, so these are overridden to post a message
    // into the iframe instead. `watchScript()` is what actually applies the
    // command on the other end.

    @Test func playPauseScriptPostsMessageToPlayerFrame() {
        let script = DropoutParser().playPauseScript()
        #expect(script.contains("getElementById('watch-embed')"))
        #expect(script.contains("postMessage"))
        #expect(script.contains("playPause"))
        #expect(!script.contains("querySelector('video')"))
    }

    @Test func seekBackScriptPostsMessageToPlayerFrame() {
        let script = DropoutParser().seekBackScript()
        #expect(script.contains("postMessage"))
        #expect(script.contains("seekBack"))
    }

    @Test func seekForwardScriptPostsMessageToPlayerFrame() {
        let script = DropoutParser().seekForwardScript()
        #expect(script.contains("postMessage"))
        #expect(script.contains("seekForward"))
    }

    @Test func watchScriptListensForControlMessagesAndCanRelayToChildFrames() {
        // Every frame needs to both apply a control command to a local
        // video and relay it further down, since the actual player may be
        // nested more than one iframe deep.
        let script = DropoutParser().watchScript()
        #expect(script.contains("addEventListener('message'"))
        #expect(script.contains("applyControl"))
        #expect(script.contains("getElementsByTagName('iframe')"))
    }
}
