import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var model: ShareFormModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Leaving only through ✕ or Save keeps the temp files cleaned up.
        isModalInPresentation = true
        let model = ShareFormModel(context: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareFormView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
