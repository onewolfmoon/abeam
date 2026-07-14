import SwiftUI
@preconcurrency import WebKit

// A thin async/SwiftUI wrapper around WKWebView, standing in for the
// SwiftUI-native WebPage/WebView API (macOS 26+), which isn't available on
// macOS 15.
@MainActor
public final class BrowserPage {
    public let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Never>?

    public init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigationDelegate
    }

    private lazy var navigationDelegate = NavigationDelegate(owner: self)

    // Waits for the navigation to finish (or fail); errors are swallowed,
    // matching callers that treat "did it finish" as a best-effort signal
    // rather than something to react to.
    public func load(_ request: URLRequest) async {
        await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            webView.load(request)
        }
    }

    fileprivate func navigationDidComplete() {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    // The script body runs as an implicit async function, with `arguments`
    // bound as its named parameters, so callers can `return` a value or
    // `await` inside it exactly as with WebPage.callJavaScript.
    @discardableResult
    public func callJavaScript(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        // The result is always a JSON-bridged value (String/NSNumber/NSArray/
        // NSDictionary/NSNull); boxed to cross the continuation since `Any`
        // itself isn't statically Sendable.
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedBox<Any?>, Error>) in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: UncheckedBox(value))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.value
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private unowned let owner: BrowserPage

    init(owner: BrowserPage) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.navigationDidComplete()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner.navigationDidComplete()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner.navigationDidComplete()
    }
}

public struct BrowserView: NSViewRepresentable {
    private let page: BrowserPage

    public init(_ page: BrowserPage) {
        self.page = page
    }

    public func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
