import OSLog
import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private static let logger = Logger(
        subsystem: "dev.wolfmoon.Abeam.SendToAbaft", category: "ShareViewController"
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.logger.notice("viewDidLoad")

        let hosting = UIHostingController(
            rootView: ShareView(extensionContext: extensionContext)
        )
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}
