import SwiftUI
import ReplayKit

// Wraps Apple's system broadcast-picker button, which is the only supported
// way to start an RPBroadcastSampleHandler-based extension: apps cannot
// start a broadcast programmatically, the user must tap this system control.
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtensionBundleID: String

    private static let side: CGFloat = 50

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))

        // Non-zero frame at init deliberately, not .zero: RPSystemBroadcastPickerView
        // runs its one-time internal extension/icon lookup based on the frame
        // it's given at construction, and never retries once Auto Layout
        // gives it a real size afterward — a .zero initial frame (e.g. from
        // UIViewRepresentable sizing it purely via SwiftUI's .frame()
        // modifier after the fact) leaves it permanently blank and inert.
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            picker.topAnchor.constraint(equalTo: container.topAnchor),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        picker.preferredExtension = preferredExtensionBundleID
        picker.showsMicrophoneButton = false
        picker.tintColor = .label

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
