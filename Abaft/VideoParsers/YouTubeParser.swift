import Foundation

/// A parser that parses share payloads from YouTube.
struct YouTubeParser: VideoParser {
    let identifier = "youtube"
    let displayName = "YouTube"

    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
    ]

    func parse(_ payload: String) -> URL? {
        guard let url = firstURL(in: payload), let host = url.host?.lowercased()
        else { return nil }
        return Self.hosts.contains(host) ? url : nil
    }
}
