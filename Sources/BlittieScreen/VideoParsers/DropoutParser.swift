import Foundation

// Claims any payload containing a dropout.tv link. Dropout's share sheet
// hands over freeform text with the link embedded, e.g.:
//   "I'm watching Count the Rice on Dropout\nhttp://watch.dropout.tv/videos/count-the-rice"
// and the link itself is plain http:// — upgraded to https:// here since App
// Transport Security blocks cleartext loads in the WebView by default, and
// the site supports https anyway.
struct DropoutParser: VideoParser {
    let identifier = "dropout"

    func parse(_ payload: String) -> URL? {
        guard let url = firstURL(in: payload), let host = url.host?.lowercased() else { return nil }
        guard host == "dropout.tv" || host.hasSuffix(".dropout.tv") else { return nil }

        guard url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }
}
