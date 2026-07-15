import SwiftUI
import SenderKit

struct ReceiverPickerSheet: View {
    @Binding var receiverAddress: String
    @Environment(\.dismiss) private var dismiss

    @State private var manualAddress: String = ""
    @State private var connectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a Receiver")
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
            discoveryPlaceholder

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
        .onAppear { manualAddress = receiverAddress }
    }

    private var discoveryPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            Text("Automatic discovery is coming soon")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    private func connect() {
        let trimmed = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectError = "Enter an IP address or hostname."
            return
        }
        connectError = nil
        receiverAddress = trimmed
        ReceiverAddressStore.address = trimmed
        dismiss()
    }
}

#Preview {
    ReceiverPickerSheet(receiverAddress: .constant(""))
}
