import MirrorKit
import ReceiverProtocol
import SwiftUI

// Native counterpart to vga's MirrorView: same three-step handshake (pick
// content, hand the offer to the Receiver over the shared WebSocket
// connection, apply its answer), just calling into MirrorKit's
// ScreenPicker/WebRTCMirrorSession instead of a WKWebView running
// mirror.html's getDisplayMedia + browser RTCPeerConnection.
//
// iOS 27 minimum: ScreenPicker/WebRTCMirrorSession are both iOS-27-gated;
// callers must check MirrorKit.isScreenMirroringSupported before reaching
// this view (see ContentView's mirrorContent).
@available(iOS 27, *)
struct MirrorView: View {
    @Bindable var model: AppModel

    @State private var picker = ScreenPicker()
    @State private var session = WebRTCMirrorSession()
    @State private var watchTask: Task<Void, Never>?
    @State private var filterUpdateTask: Task<Void, Never>?
    @State private var sessionTask: Task<Void, Never>?
    @State private var isMirroring = false
    @State private var statusMessage: String?
    @State private var startedAt: Date?

    var body: some View {
        VStack(spacing: 20) {
            statusView
                .font(.callout)
                .foregroundStyle(.secondary)

            startMirroringButton
        }
        // Stop the session but keep it, and cancel sessionTask too so switching away mid-handshake doesn't leave a half-started capture running.
        .onDisappear {
            watchTask?.cancel()
            filterUpdateTask?.cancel()
            sessionTask?.cancel()
            if isMirroring {
                Task { await session.stop() }
            }
            Task { await picker.stopObserving() }
        }
    }

    @ViewBuilder
    private var startMirroringButton: some View {
        let button = Button(isMirroring ? "Stop Mirroring" : "Start Mirroring")
        { sessionTask = Task { await toggleMirroring() } }
        .tint(isMirroring ? .red : .accentColor)
        .controlSize(.large)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let statusMessage {
            Text(statusMessage)
        } else if isMirroring, let startedAt {
            Text(
                "Mirroring to \(model.receiverName) · \(startedAt, style: .timer)"
            )
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

    private func startMirroring() async {
        statusMessage = "waiting for content picker…"
        do {
            let filter = try await picker.pickContent()
            try Task.checkCancellation()

            statusMessage = "starting capture…"
            let offer = try await session.startMirroring(filter: filter)
            try Task.checkCancellation()

            statusMessage = "connecting to receiver…"
            let answer = try await model.sendOffer(sdp: offer)
            try Task.checkCancellation()

            try await session.applyAnswer(sdp: answer)
            try Task.checkCancellation()

            statusMessage = nil
            startedAt = Date()
            isMirroring = true
            watchForDisconnect()
            watchForFilterUpdates()
        } catch is CancellationError {
            await session.stop()
            await picker.stopObserving()
        } catch ScreenPickerError.cancelled {
            statusMessage = nil
            await picker.stopObserving()
        } catch {
            statusMessage = "error: \(error.localizedDescription)"
            await session.stop()
            await picker.stopObserving()
        }
    }

    private func stopMirroring() async {
        watchTask?.cancel()
        filterUpdateTask?.cancel()
        await session.stop()
        await picker.stopObserving()
        isMirroring = false
        startedAt = nil
        statusMessage = nil
    }

    // Reacts to the user swapping the shared window/display in place via
    // Control Center's "Windows..." control on the active share: forwards
    // each new filter straight into the running capture, no re-handshake
    // needed since the video/audio tracks and SDP never change — only the
    // frame content does.
    private func watchForFilterUpdates() {
        filterUpdateTask?.cancel()
        filterUpdateTask = Task {
            for await filter in await picker.filterUpdates() {
                guard !Task.isCancelled else { return }
                try? await session.updateFilter(filter)
            }
        }
    }

    // Reacts to the Receiver ending the session (closing its window, or a
    // different Sender preempting it) the same way vga's MirrorView reacts
    // to mirror.html's teardown() message — except here it's WebRTC's own
    // connectionState telling us directly, no JS bridge involved.
    private func watchForDisconnect() {
        watchTask?.cancel()
        watchTask = Task {
            for await state in await session.connectionStates() {
                guard !Task.isCancelled else { return }
                switch state {
                case .disconnected, .failed, .closed:
                    isMirroring = false
                    startedAt = nil
                    statusMessage = nil
                    return
                case .new, .connecting, .connected:
                    continue
                }
            }
        }
    }
}
