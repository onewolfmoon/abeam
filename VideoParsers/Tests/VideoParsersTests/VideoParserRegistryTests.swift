import Testing

@testable import VideoParsers

/// Tests for `VideoParserRegistry`'s parser precedence: which parser wins
/// when more than one could plausibly handle a payload.
struct VideoParserRegistryTests {

    @Test func youtubeURLIsHandledByYouTubeParserNotCatchall() throws {
        let result = try #require(VideoParserRegistry.default.parse("https://youtu.be/abc123"))
        #expect(result.parser.identifier == "youtube")
    }

    @Test func dropoutURLIsHandledByDropoutParserNotCatchall() throws {
        let result = try #require(
            VideoParserRegistry.default.parse("https://watch.dropout.tv/videos/count-the-rice")
        )
        #expect(result.parser.identifier == "dropout")
    }

    @Test func unrecognizedURLFallsBackToCatchall() throws {
        let result = try #require(VideoParserRegistry.default.parse("https://example.com/some-page"))
        #expect(result.parser.identifier == "catchall")
    }

    @Test func payloadWithNoURLIsNotHandledByAnyParser() {
        #expect(VideoParserRegistry.default.parse("just some text, no link here") == nil)
    }
}
