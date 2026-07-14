import Foundation

// Shared between the main app and the broadcast extension (two separate
// processes) via an App Group container, so the address typed into the
// app's UI is visible to the extension when it starts a broadcast.
public enum ReceiverAddressStore {
    public static let appGroupID = "group.com.wesleymoy.vgasender"
    private static let key = "receiverAddress"

    public static var address: String {
        get { defaults?.string(forKey: key) ?? "" }
        set { defaults?.set(newValue, forKey: key) }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}
