import ReceiverProtocol
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            TabView(selection: $model.mode) {
                ForEach(SenderMode.allCases) { mode in
                    Tab(
                        mode.title,
                        systemImage: mode.systemImage,
                        value: mode
                    ) {
                        screen(for: mode)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
        .frame(minWidth: 320, minHeight: 400)
        .sheet(isPresented: $model.showReceiverSheet) {
            ReceiverPickerSheet(model: model)
        }
    }

    @ViewBuilder
    private func screen(for mode: SenderMode) -> some View {
        NavigationStack {
            content
                .navigationTitle(mode.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        ReceiverStatusLabel(model: model)
                    }.sharedBackgroundVisibility(.hidden)

                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            model.showReceiverSheet = true
                        }) {
                            Label(
                                model.hasReceiver ? "Change Receiver" : "Choose Receiver",
                                systemImage: "network"
                            )
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if !model.hasReceiver {
                EmptyReceiverView(model: model)
            } else {
                switch model.mode {
                case .video:
                    SendVideoView(model: model)
                case .mirror:
                    mirrorContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mirrorContent: some View {
        #if canImport(ScreenCaptureKit)
                MirrorView(model: model)
        #else
            // Not usually reachable because navigation prevents accessing this
            // page when ScreenCaptureKit isn't available.
            mirroringUnavailable
        #endif
    }

    private var mirroringUnavailable: some View {
        ContentUnavailableView {
            Label(
                "Mirroring Unavailable",
                systemImage: "rectangle.on.rectangle.slash"
            )
        } description: {
            Text("Screen mirroring is not available on this device.")
        }
    }
}

private struct ReceiverStatusLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(model.receiverName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary.opacity(0.3)
        }
    }

    // The dot above is decorative (accessibilityHidden) since it's the only
    // place connection state is conveyed visually — this is the text
    // VoiceOver actually reads instead.
    private var accessibilityText: String {
        guard model.hasReceiver else { return model.receiverName }
        switch model.connectionState {
        case .connected: return "Connected to \(model.receiverName)"
        case .connecting: return "Connecting to \(model.receiverName)"
        case .failed: return "Connection to \(model.receiverName) failed"
        case .disconnected: return "Disconnected from \(model.receiverName)"
        }
    }
}

private struct EmptyReceiverView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Receiver to get started", systemImage: "tv")
        } actions: {
            Button("Choose Receiver") {
                model.showReceiverSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
