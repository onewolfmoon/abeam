import Foundation
import Testing

@testable import VideoParsers

struct YouTubeParserTests {

    @Test(arguments: [
        "https://youtube.com/watch?v=abc123",
        "https://www.youtube.com/watch?v=abc123",
        "https://m.youtube.com/watch?v=abc123",
        "https://youtu.be/abc123",
    ])
    func parsesRecognizedHosts(_ url: String) throws {
        let parsed = try #require(YouTubeParser().parse(url))
        #expect(parsed.absoluteString == url)
    }

    @Test func rejectsUnrecognizedHost() {
        #expect(YouTubeParser().parse("https://example.com/watch?v=abc123") == nil)
    }

    @Test func extractsURLFromSurroundingShareText() throws {
        let payload = "Check this out: https://youtu.be/abc123 it's great"
        let parsed = try #require(YouTubeParser().parse(payload))
        #expect(parsed.absoluteString == "https://youtu.be/abc123")
    }

    @Test func returnsNilForPayloadWithNoURL() {
        #expect(YouTubeParser().parse("no link in this text") == nil)
    }

    @Test func hostMatchingIsCaseInsensitive() throws {
        let parsed = try #require(YouTubeParser().parse("https://YouTube.com/watch?v=abc123"))
        #expect(parsed.host?.lowercased() == "youtube.com")
    }
}
