import Foundation

/// A parser that parses share payloads from Dropout.
///
/// > I'm watching Count the Rice on Dropout
/// >
/// > http://watch.dropout.tv/videos/count-the-rice
///
/// This parser also replaces the `http` scheme with `https`, as App Transport
/// Security disallows insecure network connections over the internet.
struct DropoutParser: VideoParser {
    let identifier = "dropout"

    func parse(_ payload: String) -> URL? {
        guard let url = firstURL(in: payload), let host = url.host?.lowercased()
        else { return nil }
        guard host == "dropout.tv" || host.hasSuffix(".dropout.tv") else {
            return nil
        }

        guard url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }
}
