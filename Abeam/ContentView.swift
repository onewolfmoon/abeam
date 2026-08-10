import SwiftUI
import ReceiverProtocol

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            // A tab bar/sidebar with a single entry (iOS below 27, where
            // Mirror Screen is unavailable — see SenderMode.availableCases)
            // is just chrome around one screen; skip TabView entirely there.
            if SenderMode.availableCases.count > 1 {
                TabView(selection: $model.mode) {
                    ForEach(SenderMode.availableCases) { mode in
                        Tab(mode.title, systemImage: mode.systemImage, value: mode) {
                            screen(for: mode)
                        }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
            } else {
                screen(for: model.mode)
            }
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
                    recevierStatusLabelItem()
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            model.showReceiverSheet = true
                        }) {
                            Label(model.hasReceiver ? "Change" : "Choose Screen", systemImage: "network")
                        }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private func recevierStatusLabelItem() -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                ReceiverStatusLabel(model: model)
            }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                ReceiverStatusLabel(model: model)
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

    // MirrorView requires iOS 27 (ScreenCaptureKit). SenderMode.availableCases
    // keeps .mirror out of reach of the tab UI below that, but model.mode is
    // settable from outside this view (e.g. a future deep link), so the
    // `else` below is reachable in practice, not just a compiler formality.
    @ViewBuilder
    private var mirrorContent: some View {
        if #available(iOS 27, *) {
            MirrorView(model: model)
        } else {
            ContentUnavailableView {
                Label("Mirroring Unavailable", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text("Screen mirroring requires iOS 27 or later.")
            }
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
            Label("Choose a Screen to get started", systemImage: "tv")
        } actions: {
            Button("Choose Screen") {
                model.showReceiverSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
