import QuickLook
import SwiftUI
import UIKit

/// The app stays portrait, except while a viewer (web archive, screenshot, Quick Look) is on screen.
/// Info.plist lists all orientations; this narrows them per screen.
@MainActor
enum OrientationGate {
    private static var landscapeViewers = 0

    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        landscapeViewers > 0 || isQuickLook(top(of: window?.rootViewController)) ? .allButUpsideDown : .portrait
    }

    static func viewerAppeared() { landscapeViewers += 1 }

    static func viewerDisappeared() {
        landscapeViewers = max(0, landscapeViewers - 1)
        settle()
    }

    /// Turns the screen back to portrait once no viewer needs landscape (rotation does not happen on its own).
    static func settle() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene, let root = scene.keyWindow?.rootViewController else { return }
        guard mask(for: scene.keyWindow) == .portrait else { return }
        root.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    static func top(of controller: UIViewController?) -> UIViewController? {
        var top = controller
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func isQuickLook(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        return controller is QLPreviewController || controller.children.contains(where: isQuickLook)
    }
}

final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationGate.mask(for: window) }
    }
}

extension View {
    /// Lets the screen turn to landscape while this view is shown.
    func allowsLandscape() -> some View {
        onAppear { OrientationGate.viewerAppeared() }
            .onDisappear { OrientationGate.viewerDisappeared() }
    }
}
