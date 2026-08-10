import Foundation

// Persists the selected Receiver in the shared App Group container so the
// main app and the "Send to Abaft" share extension agree on which Receiver
// to use without the extension having to re-browse on every share.
public enum ReceiverEndpointStore {
    public static let appGroupID = "group.dev.wolfmoon.Abeam"
    private static let key = "abeamReceiverAddress"

    // Force-unwrapped deliberately: a nil result here means the calling
    // target is missing the App Group entitlement, which is a build
    // misconfiguration, not a condition to degrade gracefully around — doing
    // so silently would just mean the app and extension write to two
    // different UserDefaults stores without any signal that they've drifted.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }

    public static var current: ReceiverEndpoint? {
        get { defaults.string(forKey: key).flatMap(ReceiverEndpoint.init(persistedString:)) }
        set { defaults.set(newValue?.persistedString, forKey: key) }
    }
}
