import QuickLook
import Testing
import UIKit

@testable import Sharesheet

@MainActor
struct OrientationGateTests {
    @Test func portraitOnlyUntilAViewerAppears() {
        #expect(OrientationGate.mask(for: nil) == .portrait)
        OrientationGate.viewerAppeared()
        #expect(OrientationGate.mask(for: nil) == .allButUpsideDown)
        OrientationGate.viewerDisappeared()
        #expect(OrientationGate.mask(for: nil) == .portrait)
    }

    @Test func quickLookOnTopAllowsLandscape() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        #expect(OrientationGate.mask(for: window) == .portrait)
        root.present(UINavigationController(rootViewController: QLPreviewController()), animated: false)
        #expect(OrientationGate.mask(for: window) == .allButUpsideDown)
    }
}
