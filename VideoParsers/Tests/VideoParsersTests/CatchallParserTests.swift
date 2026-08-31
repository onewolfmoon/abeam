import Foundation
import Testing

@testable import VideoParsers

struct CatchallParserTests {

    @Test func parsesAnyHTTPSURLRegardlessOfHost() throws {
        let parsed = try #require(CatchallParser().parse("https://example.com/some-page"))
        #expect(parsed.absoluteString == "https://example.com/some-page")
    }

    @Test func extractsURLFromSurroundingShareText() throws {
        let parsed = try #require(
            CatchallParser().parse("Look at this: https://example.com/some-page neat right?")
        )
        #expect(parsed.absoluteString == "https://example.com/some-page")
    }

    @Test func returnsNilForPayloadWithNoURL() {
        #expect(CatchallParser().parse("no link in this text") == nil)
    }
}
