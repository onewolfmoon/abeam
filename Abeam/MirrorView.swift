#if canImport(ScreenCaptureKit)
    import MirrorKit
    import ReceiverProtocol
    @preconcurrency import ScreenCaptureKit
    import SwiftUI
    #if os(iOS)
        import UIKit
    #endif

    /// A screen that contains screen mirroring controls.
    ///
    /// This screen assumes that the user has already connected to an Abaft
    /// screen.
    @available(iOS 27, *)
    struct MirrorView: View {
        private enum Lifecycle: Equatable {
            case idle
            case starting
            case active(startedAt: Date)

            var isActive: Bool {
                if case .active = self { return true }
                return false
            }
        }

        @Bindable var model: AppModel

        @State private var picker = ScreenPicker()
        @State private var session = WebRTCMirrorSession()
        @State private var watchTask: Task<Void, Never>?
        @State private var filterUpdateTask: Task<Void, Never>?
        @State private var sessionTask: Task<Void, Never>?
        @State private var lifecycle: Lifecycle = .idle
        @State private var statusMessage: String?
        @State private var contentOptimization: WebRTCMirrorSession.ContentOptimization = .textAndImages
        // The filter last handed to the running capture, either from
        // startMirroring() or a picker swap. Kept around so device rotation
        // (iOS only) has something to re-issue to session.updateFilter(),
        // which recomputes capture dimensions for the filter's current
        // contentRect. See #79: ScreenCaptureKit doesn't resize the capture
        // on its own when the device rotates.
        @State private var currentFilter: SCContentFilter?

        var body: some View {
            VStack(spacing: 20) {
                if case .active(let startedAt) = lifecycle {
                    MirrorPreviewView(session: session, epoch: startedAt)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                statusView
                    .font(.callout)
                    .foregroundStyle(.secondary)

                contentOptimizationPicker

                startMirroringButton
            }
            .padding()
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
                if lifecycle.isActive {
                    Task {
                        await sendStopSignal()
                        await session.stop()
                    }
                }
                Task { await picker.stopObserving() }
            }
            #if os(iOS)
                .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
                ) { _ in
                    // TODO(#79 diagnostics): drop this log once rotation is
                    // confirmed fixed end to end. Correlate against
                    // MirrorKit[#79] buffer/contentRect log lines.
                    print(
                        "MirrorKit[#79]: \(Date()) UIDevice.orientation -> \(UIDevice.current.orientation.rawValue)"
                    )
                    guard lifecycle.isActive, let currentFilter else { return }
                    Task { try? await session.updateFilter(currentFilter) }
                }
            #endif
        }

        @ViewBuilder
        private var contentOptimizationPicker: some View {
            Picker("Optimize for", selection: $contentOptimization) {
                Text("Motion").tag(WebRTCMirrorSession.ContentOptimization.motion)
                Text("Text and Images").tag(WebRTCMirrorSession.ContentOptimization.textAndImages)
            }
            .disabled(lifecycle != .idle)
        }

        @ViewBuilder
        private var startMirroringButton: some View {
            let button = Button(
                lifecycle.isActive ? "Stop Mirroring" : "Start Mirroring"
            ) { sessionTask = Task { await toggleMirroring() } }
            .tint(lifecycle.isActive ? .red : .accentColor)
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
            } else if case .active(let startedAt) = lifecycle {
                Text(
                    "Mirroring to \(model.receiverName) · \(startedAt, style: .timer)"
                )
            } else {
                Text("Not mirroring")
            }
        }

        private func toggleMirroring() async {
            if lifecycle.isActive {
                await stopMirroring()
            } else {
                await startMirroring()
            }
        }

        private func startMirroring() async {
            lifecycle = .starting
            statusMessage = "waiting for content picker…"
            do {
                let filter = try await picker.pickContent()
                currentFilter = filter
                try Task.checkCancellation()

                statusMessage = "starting capture…"
                let offer = try await session.startMirroring(
                    filter: filter, contentOptimization: contentOptimization)
                try Task.checkCancellation()

                statusMessage = "connecting to receiver…"
                let answer = try await model.sendOffer(sdp: offer)
                try Task.checkCancellation()

                try await session.applyAnswer(sdp: answer)
                try Task.checkCancellation()

                statusMessage = nil
                lifecycle = .active(startedAt: Date())
                watchForDisconnect()
                watchForFilterUpdates()
            } catch is CancellationError {
                lifecycle = .idle
                await sendStopSignal()
                await session.stop()
                await picker.stopObserving()
            } catch ScreenPickerError.cancelled {
                lifecycle = .idle
                statusMessage = nil
                await picker.stopObserving()
            } catch {
                lifecycle = .idle
                statusMessage = "error: \(error.localizedDescription)"
                await sendStopSignal()
                await session.stop()
                await picker.stopObserving()
            }
        }

        private func stopMirroring() async {
            watchTask?.cancel()
            filterUpdateTask?.cancel()
            await sendStopSignal()
            await session.stop()
            await picker.stopObserving()
            lifecycle = .idle
            statusMessage = nil
        }

        /// Tells the Abaft screen that screen mirroring is ending.
        private func sendStopSignal() async {
            _ = try? await model.sendStop()
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
                    currentFilter = filter
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
                        await sendStopSignal()
                        await picker.stopObserving()
                        lifecycle = .idle
                        statusMessage = nil
                        return
                    case .captureEnded:
                        filterUpdateTask?.cancel()
                        await sendStopSignal()
                        await picker.stopObserving()
                        lifecycle = .idle
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
