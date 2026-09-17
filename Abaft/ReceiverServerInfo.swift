import Combine

/// A publisher that pushes the port `ReceiverSocketServer` actually bound to once it's known.
///
/// Sendable: all stored state is isolated to the main actor, so it's safe to
/// mutate from a different actor's context as long as the mutation itself
/// hops to the main actor.

// `@Observable` is available in macOS 14, and the minimum deployment
// version of Abaft is macOS 13 at the time of implementation.
@MainActor
final class ReceiverServerInfo: ObservableObject, Sendable {
    @Published private(set) var port: UInt16?

    func setPort(_ port: UInt16) {
        self.port = port
    }
}
