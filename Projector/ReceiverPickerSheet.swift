import SwiftUI
import ProjectorKit

struct ReceiverPickerSheet: View {
    var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var manualAddress: String = ""
    @State private var connectError: String?
    @State private var browser = ReceiverBrowser()
    @State private var discovered: [DiscoveredReceiver] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a Blittie Screen")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.systemGray5), in: Circle())
                }
            }

            sectionHeader("On Your Network")
            discoveryList

            sectionHeader("Or Enter an Address")
            HStack(spacing: 8) {
                TextField("e.g. 192.168.1.42:8787", text: $manualAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button("Connect") {
                    connect()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let connectError {
                Text(connectError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if case .manual = appModel.receiverEndpoint {
                manualAddress = appModel.receiverEndpoint?.displayName ?? ""
            }
        }
        .task {
            await browser.start()
            while !Task.isCancelled {
                discovered = await browser.results
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            let browser = browser
            Task { await browser.stop() }
        }
    }

    private var discoveryList: some View {
        Group {
            if discovered.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text("No Blittie Screens found yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(discovered) { receiver in
                        Button {
                            select(receiver)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tv")
                                    .foregroundStyle(.secondary)
                                Text(receiver.name)
                                    .font(.system(size: 14))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    private func select(_ receiver: DiscoveredReceiver) {
        appModel.select(receiver)
        connectError = nil
        dismiss()
    }

    private func connect() {
        guard appModel.connect(to: manualAddress) else {
            connectError = "Enter an IP address or hostname."
            return
        }
        connectError = nil
        dismiss()
    }
}

#Preview {
    ReceiverPickerSheet(appModel: AppModel())
}
