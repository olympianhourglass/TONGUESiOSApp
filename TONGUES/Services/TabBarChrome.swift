import UIKit

// Drives the iPhone/iPad bottom tab bar's look. The default bar is light
// (light material, near-black icons), but full-screen black surfaces reached
// from a tab — e.g. StatisticsView — want the bar to read as dark. Those
// screens call `apply(dark: true)` on appear and `apply(dark: false)` on
// disappear.
//
// How the dark flip works: the tab-bar item colors are DYNAMIC (near-black in a
// light trait, white in a dark trait) and the background uses the system's
// adaptive default material. So the only thing needed to "go dark" is to flip
// the live bar's trait — we set `overrideUserInterfaceStyle = .dark` on it. This
// is far more robust than swapping whole appearance objects on the instance,
// which SwiftUI re-installs from the appearance proxy during a push (that's why
// the bar wasn't actually turning dark). The override is a leaf-level trait on
// the UITabBar that SwiftUI leaves alone, and both the material and the icon
// colors follow it automatically — exactly as if the bar were in dark mode.
enum TabBarChrome {

    // The single app-wide appearance: adaptive default background, dynamic
    // icon colors, icons-only (titles hidden via clear color). Because the
    // colors are dynamic, the very same appearance renders light or dark purely
    // from the bar's trait — no second appearance object required.
    static let appearance: UITabBarAppearance = {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()

        let item = UITabBarItemAppearance()
        item.normal.iconColor = dynamic(light: UIColor.black.withAlphaComponent(0.3),
                                        dark: UIColor.white.withAlphaComponent(0.4))
        item.selected.iconColor = dynamic(light: .black, dark: .white)
        let hiddenTitle: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]
        item.normal.titleTextAttributes = hiddenTitle
        item.selected.titleTextAttributes = hiddenTitle

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        return appearance
    }()

    // Install the shared appearance on the proxy. Called once at startup.
    static func installDefault() {
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    // Flip every live tab bar to a dark (or default) trait. Dark yields a dark
    // adaptive material with white icons; default restores the light look.
    static func apply(dark useDark: Bool) {
        let style: UIUserInterfaceStyle = useDark ? .dark : .unspecified
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                for bar in tabBars(in: window) {
                    bar.overrideUserInterfaceStyle = style
                    bar.setNeedsLayout()
                }
            }
        }
    }

    // MARK: - Internals

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }

    private static func tabBars(in view: UIView) -> [UITabBar] {
        var found: [UITabBar] = []
        if let bar = view as? UITabBar { found.append(bar) }
        for sub in view.subviews { found.append(contentsOf: tabBars(in: sub)) }
        return found
    }
}
