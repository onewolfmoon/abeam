import SwiftUI
@preconcurrency import WebKit

// A thin async/SwiftUI wrapper around WKWebView, standing in for the
// SwiftUI-native WebPage/WebView API (macOS 26+), which isn't available on
// macOS 15.
@MainActor
public final class BrowserPage {
    public let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private var registeredMessageNames: Set<String> = []
    private var messageContinuations: [String: [UUID: AsyncStream<String>.Continuation]] = [:]

    public init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigationDelegate
        #if DEBUG
        // Lets Safari's Develop menu attach to this WKWebView (Develop >
        // <device/Mac name> > <window>) instead of it being invisible to
        // Web Inspector, which is off by default for WKWebView.
        webView.isInspectable = true
        #endif
        // Lets the page's own transparent background show the native
        // SwiftUI content behind it instead of painting white.
        webView.underPageBackgroundColor = .clear
        // underPageBackgroundColor alone doesn't stop WKWebView's own NSView
        // layer from painting an opaque white backing — drawsBackground is
        // the flag that actually does, but it's private API (KVC-only).
        webView.setValue(false, forKey: "drawsBackground")
    }

    private lazy var navigationDelegate = NavigationDelegate(owner: self)
    private lazy var messageDelegate = MessageDelegate(owner: self)

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

    // Subscribes to messages the page posts via
    // `window.webkit.messageHandlers.<name>.postMessage(aString)`, so callers
    // can react to real page events instead of polling page state through
    // callJavaScript on a timer. Classic WKWebView's message-handler bridge
    // (unlike the still-unverified push path on the newer macOS 26 WebPage
    // API this class stands in for) is a long-established, reliable
    // mechanism. Safe to call before or after `load`. Messages are read as
    // strings (JS pages here only ever post plain strings) rather than `Any`
    // so the value can safely cross into the AsyncStream's consumer.
    public func messages(named name: String) -> AsyncStream<String> {
        if registeredMessageNames.insert(name).inserted {
            webView.configuration.userContentController.add(messageDelegate, name: name)
        }
        return AsyncStream { continuation in
            let id = UUID()
            messageContinuations[name, default: [:]][id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeMessageContinuation(name: name, id: id) }
            }
        }
    }

    // Injects a script that runs at the start of every document load in
    // this page, ahead of the page's own scripts. This is for a page-owned
    // listener that needs to be in place before content loads. For
    // example, this lets a script push events back via `messages(named:)`
    // instead of Swift polling document state on a timer.
    //
    // This method must be called before the web view loads the page. If
    // this method is called after the page starts loading, it may miss
    // events.
    //
    // Pass false when the video plays in an iframe that the top-level
    // document doesn't have permission to attach event listeners to.
    public func addUserScript(_ source: String, forMainFrameOnly: Bool = true) {
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: forMainFrameOnly
        )
        webView.configuration.userContentController.addUserScript(script)
    }

    fileprivate func didReceiveMessage(name: String, body: Any) {
        let value = (body as? String) ?? ""
        for continuation in messageContinuations[name, default: [:]].values {
            continuation.yield(value)
        }
    }

    private func removeMessageContinuation(name: String, id: UUID) {
        messageContinuations[name]?.removeValue(forKey: id)
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

@MainActor
private final class MessageDelegate: NSObject, WKScriptMessageHandler {
    private unowned let owner: BrowserPage

    init(owner: BrowserPage) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner.didReceiveMessage(name: message.name, body: message.body)
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
