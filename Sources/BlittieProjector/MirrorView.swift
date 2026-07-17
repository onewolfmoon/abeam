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
    @State private var watchTask: Task<Void, Never>?
    @State private var sessionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            BrowserView(mirrorPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(isMirroring ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                statusView
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isMirroring ? "Stop Mirroring" : "Start Mirroring") {
                    sessionTask = Task { await toggleMirroring() }
                }
                .buttonStyle(.borderedProminent)
                .tint(isMirroring ? .red : .accentColor)
            }
            .padding(16)
        }
        // Stops the session rather than just abandoning it: mirrorPage (and
        // the RTCPeerConnection/getDisplayMedia stream living in it) is kept
        // alive across mode switches at the ContentView level, so leaving
        // this state on cancel would keep mirroring in the background with
        // no UI reflecting it. sessionTask is cancelled here too, covering
        // the case where the user switches away mid-handshake (see the
        // Task.checkCancellation() calls in startMirroring below).
        .onDisappear {
            watchTask?.cancel()
            sessionTask?.cancel()
            if isMirroring {
                Task { _ = try? await mirrorPage.callJavaScript("window.__blittieStopMirroring();") }
            }
        }
    }

    // Text(_:style:.timer) ticks on its own — no app-driven timer needed to
    // keep the elapsed time current.
    @ViewBuilder
    private var statusView: some View {
        if let statusMessage {
            Text(statusMessage)
        } else if isMirroring, let startedAt {
            Text("Mirroring to \(model.receiverName) · ") + Text(startedAt, style: .timer)
        } else {
            Text("Not mirroring")
        }
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
            // Bails out (into the catch below, which tears the capture back
            // down) if the user switched away from Mirror Screen mid-flight
            // — onDisappear cancels sessionTask but can't interrupt an
            // in-progress callJavaScript call.
            try Task.checkCancellation()
            statusMessage = "connecting to receiver…"
            let answer = try await model.sendOffer(sdp: offer)
            try Task.checkCancellation()
            _ = try await mirrorPage.callJavaScript(
                "await window.__blittieApplyAnswer(answer);",
                arguments: ["answer": answer]
            )
            try Task.checkCancellation()
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

    // Reacts to mirror.html's teardown() posting a message, instead of
    // polling window.__blittieIsCapturing() on a timer. Covers every
    // teardown path (native Stop button, the OS's own screen-recording stop
    // control, or the Receiver ending the session) since they all funnel
    // through the same JS teardown().
    private func watchForExternalStop() {
        watchTask?.cancel()
        watchTask = Task {
            for await _ in mirrorPage.messages(named: "blittieMirrorStopped") {
                guard !Task.isCancelled else { return }
                isMirroring = false
                startedAt = nil
                statusMessage = nil
                return
            }
        }
    }
}
