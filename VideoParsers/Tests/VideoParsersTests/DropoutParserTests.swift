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
}
