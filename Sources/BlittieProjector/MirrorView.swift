import SwiftUI
import SignalingCore

// Owns the "Start/Stop Mirroring" trigger and status UI natively — mirror.html
// only does local WebRTC/screen-capture work and returns/accepts SDP strings
// via callJavaScript, mirroring how receiver.html already has no networking
// of its own. This keeps all wire traffic funneled through one
// ReceiverConnection per BlittieProjector instead of mirror.html opening its
// own separate connection.
struct MirrorView: View {
    @Bindable var model: AppModel
    let mirrorPage: BrowserPage

    @State private var isMirroring = false
    @State private var statusMessage: String?
    @State private var startedAt: Date?
    @State private var now = Date()
    @State private var watchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            BrowserView(mirrorPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(isMirroring ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isMirroring ? "Stop Mirroring" : "Start Mirroring") {
                    Task { await toggleMirroring() }
                }
                .buttonStyle(.borderedProminent)
                .tint(isMirroring ? .red : .accentColor)
            }
            .padding(16)
        }
        .onDisappear {
            watchTask?.cancel()
        }
    }

    private var statusText: String {
        if let statusMessage { return statusMessage }
        guard isMirroring, let startedAt else { return "Not mirroring" }
        let elapsed = Int(now.timeIntervalSince(startedAt))
        return "Mirroring to \(model.receiverName) · \(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))"
    }

    private func toggleMirroring() async {
        if isMirroring {
            await stopMirroring()
        } else {
            await startMirroring()
        }
    }

    // Single button press covers the whole handshake: capture the screen,
    // build the offer (all local, in mirror.html), then hand it to the
    // Receiver over the shared connection and apply its answer.
    private func startMirroring() async {
        statusMessage = "requesting screen share…"
        do {
            guard let offer = try await mirrorPage.callJavaScript(
                "return await window.__blittieCreateOffer();"
            ) as? String else {
                throw ReceiverRequestError(message: "mirror page did not return an offer")
            }
            statusMessage = "connecting to receiver…"
            let answer = try await model.sendOffer(sdp: offer)
            _ = try await mirrorPage.callJavaScript(
                "await window.__blittieApplyAnswer(answer);",
                arguments: ["answer": answer]
            )
            statusMessage = nil
            startedAt = Date()
            isMirroring = true
            watchForExternalStop()
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
            _ = try? await mirrorPage.callJavaScript("window.__blittieStopMirroring();")
        }
    }

    private func stopMirroring() async {
        watchTask?.cancel()
        _ = try? await mirrorPage.callJavaScript("window.__blittieStopMirroring();")
        isMirroring = false
        startedAt = nil
        statusMessage = nil
    }

    // Also doubles as the elapsed-time ticker while mirroring, matching
    // SessionCoordinator's own poll-with-sleep-loop idiom.
    private func watchForExternalStop() {
        watchTask?.cancel()
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = Date()
                let result = try? await mirrorPage.callJavaScript("return window.__blittieIsCapturing();")
                let capturing = (result as? Bool) ?? true
                if !capturing {
                    isMirroring = false
                    startedAt = nil
                    statusMessage = nil
                    return
                }
            }
        }
    }
}
