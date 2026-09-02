import SwiftUI

struct EmptyReceiverView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Receiver to get started", systemImage: "tv")
        } actions: {
            Button("Choose Receiver") {
                model.showReceiverSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    EmptyReceiverView(model: AppModel())
}
