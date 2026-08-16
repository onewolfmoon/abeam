#if canImport(ScreenCaptureKit)
    import MirrorKit
    import ReceiverProtocol
    import SwiftUI

    /// A screen that contains screen mirroring controls.
    ///
    /// This screen assumes that the user has already connected to an Abaft
    /// screen.
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
            .onDisappear {
                // Screen mirroring should stop when the user switches to
                // another mode (i.e. sending a video). These are conceptually
                // mutually exclusive features, so they're made actually
                // mutually exclusive in this app.

                watchTask?.cancel()
                filterUpdateTask?.cancel()
                // Cancel any pending handshake. This should also stop screen
                // capture.
                sessionTask?.cancel()
                // Stop the session, but do not dispose of it.
                if isMirroring {
                    Task { await session.stop() }
                }
                Task { await picker.stopObserving() }
            }
        }

        @ViewBuilder
        private var startMirroringButton: some View {
            let button = Button(
                isMirroring ? "Stop Mirroring" : "Start Mirroring"
            ) { sessionTask = Task { await toggleMirroring() } }
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

        /// Listens for and reacts to the user swapping the shared
        /// window/display.
        ///
        /// The listener that's started forwards each new filter straight into
        /// the running capture.
        private func watchForFilterUpdates() {
            filterUpdateTask?.cancel()
            filterUpdateTask = Task {
                for await filter in await picker.filterUpdates() {
                    guard !Task.isCancelled else { return }
                    try? await session.updateFilter(filter)
                }
            }
        }

        /// Listens for and reacts to the session ending.
        private func watchForDisconnect() {
            watchTask?.cancel()
            watchTask = Task {
                for await state in await session.connectionStates() {
                    guard !Task.isCancelled else { return }
                    switch state {
                    case .disconnected, .failed, .closed:
                        filterUpdateTask?.cancel()
                        await picker.stopObserving()
                        isMirroring = false
                        startedAt = nil
                        statusMessage = nil
                        return
                    case .captureEnded:
                        filterUpdateTask?.cancel()
                        await picker.stopObserving()
                        isMirroring = false
                        startedAt = nil
                        statusMessage = "shared window closed"
                        return
                    case .new, .connecting, .connected:
                        continue
                    }
                }
            }
        }
    }
#endif
