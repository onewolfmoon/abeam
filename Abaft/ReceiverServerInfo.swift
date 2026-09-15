import Combine

/// Publishes the port `ReceiverSocketServer` actually bound to, once known.
///
/// The listener binds to an OS-assigned port rather than a fixed one, so the
/// port isn't known until the listener becomes ready. This lets UI (e.g.
/// `SettingsView`) show the current port to the user.
///
/// Sendable: all mutable state is MainActor-isolated, which is what allows
/// `ReceiverSocketServer` to hold and report to this from across the actor
/// boundary (mirroring `SessionCoordinator`'s use of the same pattern).
///
/// Uses `ObservableObject`/`@Published` rather than the `Observation`
/// framework's `@Observable` macro: Abaft's deployment target is macOS 13,
/// which predates `@Observable`'s macOS 14 minimum.
@MainActor
final class ReceiverServerInfo: ObservableObject, Sendable {
    @Published private(set) var port: UInt16?

    func setPort(_ port: UInt16) {
        self.port = port
    }
}
