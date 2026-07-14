import SwiftUI
import WebKit

struct PlayerView: View {
    let url: URL

    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .ignoresSafeArea()
            // Element Fullscreen (the HTML Fullscreen API) is off by default
            // on macOS for this WebView; without it, requestFullscreen() is
            // undefined and YouTube reports "Your browser doesn't support
            // full screen."
            .webViewElementFullscreenBehavior(.enabled)
            .task {
                await loadAndGoFullscreen()
            }
    }

    @MainActor
    private func loadAndGoFullscreen() async {
        let navigationTask = Task<Void, Never> {
            do {
                for try await event in page.load(URLRequest(url: url)) {
                    if case .finished = event { return }
                }
            } catch {
                // Ignore navigation errors; the timeout below covers them.
            }
        }

        let playbackTask = Task<Void, Never> {
            while !Task.isCancelled {
                if await isVideoPlaying() { return }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        // Proceed on whichever happens first: the page finishes loading, or
        // the video starts playing. A timeout guards against YouTube states
        // we didn't anticipate (consent dialogs, slow networks, etc.). The
        // outer tasks must be cancelled *inside* the group closure: a task
        // group implicitly awaits all its children before returning, and the
        // "losing" child here is just awaiting navigationTask/playbackTask's
        // `.value`, which won't resolve until those outer tasks themselves
        // are cancelled.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await navigationTask.value }
            group.addTask { await playbackTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            navigationTask.cancel()
            playbackTask.cancel()
            group.cancelAll()
        }

        // Give the player UI a moment to settle before requesting fullscreen.
        try? await Task.sleep(for: .milliseconds(700))

        await requestFullscreen()

        // If that didn't take (e.g. the player wasn't quite ready), try once more.
        try? await Task.sleep(for: .milliseconds(1200))
        if "\(page.fullscreenState)".localizedCaseInsensitiveContains("not") {
            await requestFullscreen()
        }
    }

    private func isVideoPlaying() async -> Bool {
        let result = try? await page.callJavaScript(
            "document.querySelector('video') ? (!document.querySelector('video').paused && document.querySelector('video').currentTime > 0) : false"
        )
        return (result as? Bool) ?? false
    }

    private func requestFullscreen() async {
        _ = try? await page.callJavaScript("""
            var v = document.querySelector('video');
            if (v) { await v.requestFullscreen(); }
            """)
    }
}
