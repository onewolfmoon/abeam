import SwiftUI
import ReceiverProtocol

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            content
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
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 320, minHeight: 400)
        .sheet(isPresented: $model.showReceiverSheet) {
            ReceiverPickerSheet(model: model)
        }
    }
    
    @ToolbarContentBuilder
    private func recevierStatusLabelItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
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
                    MirrorView(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            ForEach(SenderMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Abeam")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }

    // List(data:selection:) binds selection to the element's `id` (String)
    // when Data.Element is Identifiable, not the element itself — using
    // List(selection:) with an explicit .tag(mode) instead binds directly
    // to SenderMode.
    private var selection: Binding<SenderMode?> {
        Binding(
            get: { model.mode },
            set: { if let newMode = $0 { model.mode = newMode } }
        )
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
