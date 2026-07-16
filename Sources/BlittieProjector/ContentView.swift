import SwiftUI
import SignalingCore
import ReceiverProtocol

struct ContentView: View {
    @State private var model = AppModel()
    // Loaded once and kept alive for the app's lifetime so an in-progress
    // mirror session isn't torn down by SwiftUI recreating the WebView.
    @State private var mirrorPage = BrowserPage()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            content
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .primaryAction) {
                            ReceiverStatusLabel(model: model)
                        }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            ReceiverStatusLabel(model: model)
                        }
                    }
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
        .frame(minWidth: 860, minHeight: 600)
        .sheet(isPresented: $model.showReceiverSheet) {
            ReceiverPickerSheet(model: model)
        }
        .task {
            await mirrorPage.load(URLRequest(url: SignalingPage.url(for: .mirror)))
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
                    MirrorView(model: model, mirrorPage: mirrorPage)
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
        .navigationTitle("Blittie Projector")
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
            Text(model.receiverName)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // Reflects the actual live WebSocket connection, not just "an address is
    // saved" — a real upgrade over the old HTTP model, where Sender had no
    // visibility into whether Receiver was even reachable until the next
    // request failed.
    private var statusColor: Color {
        switch model.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary.opacity(0.3)
        }
    }
}

private struct EmptyReceiverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Choose a receiver to get started")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Choose Blittie Screen") {
                model.showReceiverSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
