import Combine
import Sparkle
import SwiftUI

final class UpdaterSettingsViewModel: ObservableObject {
    private let updater: SPUUpdater

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
}

struct SettingsView: View {
    @ObservedObject private var viewModel: UpdaterSettingsViewModel
    private var receiverInfo: ReceiverServerInfo

    init(updater: SPUUpdater, receiverInfo: ReceiverServerInfo) {
        viewModel = UpdaterSettingsViewModel(updater: updater)
        self.receiverInfo = receiverInfo
    }

    var body: some View {
        Form {
            Section("Connection") {
                connectionContent
            }
            Section {
                Toggle("Check for updates once a day", isOn: $viewModel.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: $viewModel.automaticallyDownloadsUpdates)
                    .disabled(!viewModel.automaticallyChecksForUpdates)
            }
        }
        .padding()
        .frame(width: 350)
    }

    @ViewBuilder
    private var connectionContent: some View {
        if let port = receiverInfo.port {
            let addresses = LocalNetworkAddress.currentAddresses()
            if addresses.isEmpty {
                Text("No network connection").foregroundStyle(.secondary)
            } else {
                ForEach(addresses) { address in
                    LabeledContent(address.interface, value: "\(address.address):\(port)")
                        .textSelection(.enabled)
                }
            }
        } else {
            Text("Starting…").foregroundStyle(.secondary)
        }
    }
}
