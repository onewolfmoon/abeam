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

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}

struct SettingsView: View {
    @ObservedObject private var viewModel: UpdaterSettingsViewModel

    init(updater: SPUUpdater) {
        viewModel = UpdaterSettingsViewModel(updater: updater)
    }

    var body: some View {
        Form {
            Toggle("Automatically check for updates", isOn: $viewModel.automaticallyChecksForUpdates)
        }
        .padding()
        .frame(width: 350)
    }
}
