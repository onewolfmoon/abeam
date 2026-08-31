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

    init(updater: SPUUpdater) {
        viewModel = UpdaterSettingsViewModel(updater: updater)
    }

    var body: some View {
        Form {
            Toggle("Check for updates once a day", isOn: $viewModel.automaticallyChecksForUpdates)
            Toggle("Automatically download and install updates", isOn: $viewModel.automaticallyDownloadsUpdates)
                .disabled(!viewModel.automaticallyChecksForUpdates)
        }
        .padding()
        .frame(width: 350)
    }
}
