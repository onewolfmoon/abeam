import Foundation
import Testing
@testable import BlittieScreen

struct YouTubeParserTests {
    private let parser = YouTubeParser()

    @Test func claimsBareWatchURL() {
        let url = parser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(url?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func claimsShortenedYoutuDotBeLink() {
        let url = parser.parse("https://youtu.be/dQw4w9WgXcQ")
        #expect(url != nil)
    }

    @Test func claimsLinkEmbeddedInFreeformText() {
        let url = parser.parse("Check this out!\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ\nvia YouTube")
        #expect(url?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func rejectsUnrelatedHost() {
        #expect(parser.parse("http://watch.dropout.tv/videos/count-the-rice") == nil)
    }

    @Test func rejectsTextWithNoLink() {
        #expect(parser.parse("just some text, no link here") == nil)
    }
}

struct DropoutParserTests {
    private let parser = DropoutParser()

    @Test func claimsLinkExtractedFromShareText() {
        let url = parser.parse("I'm watching Count the Rice on Dropout\nhttp://watch.dropout.tv/videos/count-the-rice")
        #expect(url?.absoluteString == "https://watch.dropout.tv/videos/count-the-rice")
    }

    @Test func upgradesHTTPToHTTPS() {
        let url = parser.parse("http://watch.dropout.tv/videos/count-the-rice")
        #expect(url?.scheme == "https")
    }

    @Test func leavesHTTPSUntouched() {
        let url = parser.parse("https://watch.dropout.tv/videos/count-the-rice")
        #expect(url?.absoluteString == "https://watch.dropout.tv/videos/count-the-rice")
    }

    @Test func rejectsUnrelatedHost() {
        #expect(parser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
    }
}

struct VideoParserRegistryTests {
    @Test func picksTheMatchingParser() {
        let result = VideoParserRegistry.default.parse("http://watch.dropout.tv/videos/count-the-rice")
        #expect(result?.parser.identifier == "dropout")
    }

    @Test func returnsNilWhenNoParserClaimsIt() {
        #expect(VideoParserRegistry.default.parse("not a link at all") == nil)
    }
}
