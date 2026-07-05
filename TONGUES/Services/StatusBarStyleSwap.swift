import UIKit
import ObjectiveC.runtime

// Why this exists:
//
// TONGUES's app-wide `.preferredColorScheme(.light)` (set on the
// WindowGroup) forces every UIHostingController in the SwiftUI app
// to publish a light trait collection. That trait collection is what
// the system reads when computing the status-bar style — so setting
// `window.overrideUserInterfaceStyle = .dark` from UIKit is shadowed
// by SwiftUI on the next layout pass and the bar stays black.
//
// The only reliable way to override the bar without giving up the
// light SwiftUI trait elsewhere is to override the UIHostingController's
// `preferredStatusBarStyle` getter itself. Since UIHostingController
// is a generic class whose concrete specialization changes between
// SwiftUI versions, we can't write a plain subclass. Instead we
// build a runtime subclass of *whatever* hosting class is actually
// in use via `objc_allocateClassPair`, and reclass the live instance
// into it with `object_setClass`. That gives the existing controller
// the override without disturbing its state.
enum StatusBarStyleSwap {

    // Tracks which controller instances have already been re-classed
    // so we don't pay the work twice when the user taps the same tab.
    private static var rewrittenObjectIds: Set<ObjectIdentifier> = []

    // Walks every UIWindow on every connected scene and re-classes
    // each root view controller into a runtime subclass that reads
    // its status-bar style from AppTabRouter. Then forces an
    // immediate appearance update. Idempotent per-instance.
    static func installAndRefresh() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let root = window.rootViewController else { continue }
                installOverride(on: root)
                // Cascade down to children + presented controllers so
                // nested hosting controllers (sheets, fullScreenCovers)
                // are also rewritten — without this, presenting a
                // sheet would leave the bar in whatever style the
                // child controller computes.
                refreshControllerTree(from: root)
            }
        }
    }

    // MARK: - Internals

    private static func refreshControllerTree(from vc: UIViewController) {
        vc.setNeedsStatusBarAppearanceUpdate()
        for child in vc.children {
            installOverride(on: child)
            refreshControllerTree(from: child)
        }
        if let presented = vc.presentedViewController {
            installOverride(on: presented)
            refreshControllerTree(from: presented)
        }
    }

    private static func installOverride(on vc: UIViewController) {
        let key = ObjectIdentifier(vc)
        if rewrittenObjectIds.contains(key) {
            vc.setNeedsStatusBarAppearanceUpdate()
            return
        }

        let baseClass: AnyClass = type(of: vc)
        let baseClassName = NSStringFromClass(baseClass)
        let subclassName = "StatusBarOverride_\(baseClassName)"

        let targetClass: AnyClass
        if let existing = NSClassFromString(subclassName) {
            targetClass = existing
        } else {
            guard let newClass = objc_allocateClassPair(baseClass, subclassName, 0) else {
                // Couldn't allocate — fall back to leaving the
                // original class in place. Status bar will revert to
                // its SwiftUI-derived style, which is the same as
                // the old behavior, so failure here is a no-op.
                return
            }

            // Block that becomes the new preferredStatusBarStyle getter.
            // The block receives `self` as its first parameter — that's
            // how imp_implementationWithBlock bridges block ABI to
            // Objective-C method ABI.
            let styleBlock: @convention(block) (UIViewController) -> UIStatusBarStyle = { _ in
                // Light override wins outright — dark full-screen surfaces
                // reachable from any tab need white content regardless of
                // the tab-derived style or the dark override.
                if AppTabRouter.shared.forceLightStatusBar { return .lightContent }
                if AppTabRouter.shared.forceDarkStatusBar { return .darkContent }
                return AppTabRouter.shared.current.needsLightStatusBarContent
                    ? .lightContent
                    : .darkContent
            }
            let styleImp = imp_implementationWithBlock(styleBlock)
            let styleSelector = #selector(getter: UIViewController.preferredStatusBarStyle)
            // Type encoding: returns q (signed 64-bit, matches NSInteger
            // = UIStatusBarStyle), takes @ (self) and : (_cmd).
            class_addMethod(newClass, styleSelector, styleImp, "q@:")

            // Force `childForStatusBarStyle` to nil so iOS reads from
            // this controller directly. SwiftUI's hosting controller
            // sometimes vends a child whose preferredStatusBarStyle
            // is consulted instead; nilling the child route closes
            // that escape hatch.
            let childBlock: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
            let childImp = imp_implementationWithBlock(childBlock)
            let childSelector = #selector(getter: UIViewController.childForStatusBarStyle)
            class_addMethod(newClass, childSelector, childImp, "@@:")

            objc_registerClassPair(newClass)
            targetClass = newClass
        }

        object_setClass(vc, targetClass)
        rewrittenObjectIds.insert(key)
        vc.setNeedsStatusBarAppearanceUpdate()
    }
}
