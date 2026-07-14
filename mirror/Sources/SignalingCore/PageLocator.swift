import Foundation

public enum SignalingRole: String {
    case sender
    case receiver
}

public enum SignalingPage {
    public static func url(for role: SignalingRole) -> URL {
        guard let url = Bundle.module.url(
            forResource: role.rawValue,
            withExtension: "html",
            subdirectory: "Resources"
        ) else {
            fatalError("\(role.rawValue).html not found in SignalingCore resources")
        }
        return url
    }
}
