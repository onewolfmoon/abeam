import Foundation

public enum ReceiverAddressStore {
    private static let key = "receiverAddress"

    public static var endpoint: ReceiverEndpoint? {
        get {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return nil }
            return ReceiverEndpoint(persistedString: saved)
        }
        set { UserDefaults.standard.set(newValue?.persistedString, forKey: key) }
    }
}
