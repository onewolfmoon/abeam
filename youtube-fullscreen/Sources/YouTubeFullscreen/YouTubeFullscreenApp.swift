import AppKit
import Foundation

@main
enum YouTubeFullscreenMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

enum AppArguments {
    static let youTubeURL: URL = {
        guard CommandLine.arguments.count > 1,
              let url = URL(string: CommandLine.arguments[1]),
              let scheme = url.scheme, scheme.hasPrefix("http")
        else {
            FileHandle.standardError.write(Data("""
            Usage: swift run YouTubeFullscreen <youtube-url>

            Example:
              swift run YouTubeFullscreen "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

            """.utf8))
            exit(1)
        }
        return url
    }()
}
