import Foundation

/// A place to persist the selected Abaft screen. This store is backed by the
/// shared App Group container so the main app and the share extension agree on
/// which screen to use without the extension having to re-browse on every
/// share.
public enum ReceiverEndpointStore {
    public static let appGroupID = "group.dev.wolfmoon.Abeam"
    private static let key = "abeamReceiverAddress"

    private static var defaults: UserDefaults {
        // Fail-fast if the App Group entitlement is missing.
        UserDefaults(suiteName: appGroupID)!
    }

    public static var current: ReceiverEndpoint? {
        get {
            defaults.string(forKey: key).flatMap(
                ReceiverEndpoint.init(persistedString:)
            )
        }
        set { defaults.set(newValue?.persistedString, forKey: key) }
    }
}
