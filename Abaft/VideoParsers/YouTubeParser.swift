import Foundation

// Claims any payload containing a youtube.com/youtu.be link. The URL is
// passed straight through unmodified — Screen just navigates the WebView to
// the normal watch page and drives the native <video> element it renders,
// same as before this parser existed.
struct YouTubeParser: VideoParser {
    let identifier = "youtube"

    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
    ]

    func parse(_ payload: String) -> URL? {
        guard let url = firstURL(in: payload), let host = url.host?.lowercased() else { return nil }
        return Self.hosts.contains(host) ? url : nil
    }
}
