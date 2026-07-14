import Foundation

public enum ReceiverAddressStore {
    private static let key = "receiverAddress"

    public static var address: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
