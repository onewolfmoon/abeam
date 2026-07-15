import SwiftUI
import SignalingCore
import ReceiverProtocol

// The light gray content-pane background shared by every mode, including
// mirror.html, which paints the same color itself so the WebView blends in
// without needing a transparent WKWebView.
private let paneBackground = Color(red: 0.969, green: 0.969, blue: 0.973)

struct ContentView: View {
    @State private var model = AppModel()
    // Loaded once and kept alive for the app's lifetime so an in-progress
    // mirror session isn't torn down by SwiftUI recreating the WebView.
    @State private var mirrorPage = BrowserPage()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            VStack(spacing: 0) {
                TopBar(model: model)
                Divider()
                content
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
        .background(paneBackground)
    }
}

private struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SenderMode.allCases) { mode in
                SidebarRow(mode: mode, isSelected: model.mode == mode) {
                    model.mode = mode
                }
            }
            Spacer()
        }
        .padding(8)
        .navigationTitle("Sender")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }
}

private struct SidebarRow: View {
    let mode: SenderMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.systemImage)
                    .frame(width: 20)
                Text(mode.title)
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Text(model.mode.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.receiverName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(model.hasReceiver ? "Change" : "Choose Receiver") {
                    model.showReceiverSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
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
            Button("Choose Receiver") {
                model.showReceiverSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
