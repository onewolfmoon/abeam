import SwiftUI

struct ReceiverPickerSheet: View {
    @Bindable var model: AppModel
    @State private var manualAddress = ""
    @State private var connectError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a Receiver")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("ON YOUR NETWORK")
                // Bonjour autodiscovery lands in a later phase; for now this
                // section just points people at manual entry below.
                Text("No receivers found yet. Enter an address below to connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("OR ENTER AN ADDRESS")
                HStack {
                    TextField("e.g. 192.168.1.42 or living-room.local", text: $manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let connectError {
                    Text(connectError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            manualAddress = model.receiverAddress ?? ""
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func connect() {
        guard model.connect(to: manualAddress) else {
            connectError = "Enter an IP address or hostname."
            return
        }
        connectError = nil
        dismiss()
    }
}
