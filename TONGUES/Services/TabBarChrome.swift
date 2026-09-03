import UIKit

// Drives the iPhone/iPad bottom tab bar's look. The app ships a light bar
// (light material, black icons) as its default, but full-screen black
// surfaces reached from a tab — e.g. StatisticsView — need the bar to read
// as dark so its icons stay legible. Those screens call `apply(dark: true)`
// on appear and `apply(dark: false)` on disappear.
//
// The catch: `UITabBar.appearance()` is a proxy that only styles bars created
// *after* it's set, so it can't restyle the live bar mid-session. This helper
// instead walks the window hierarchy, finds the live UITabBar instance(s), and
// swaps their appearance directly — the same "reach into UIKit" approach the
// status bar uses (see StatusBarStyleSwap).
enum TabBarChrome {

    // Default bar: light material, black icons, icons-only (titles hidden via
    // clear color). Matches the palette every tab except the dark ones use.
    static let light: UITabBarAppearance = {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.stackedLayoutAppearance = itemAppearance(
            unselected: UIColor.black.withAlphaComponent(0.3),
            selected: .black
        )
        mirrorLayouts(on: appearance)
        return appearance
    }()

    // Dark bar for black-backdrop screens: opaque black material, white icons.
    // Mirrors the light bar's icons-only layout so only the colors differ.
    static let dark: UITabBarAppearance = {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.stackedLayoutAppearance = itemAppearance(
            unselected: UIColor.white.withAlphaComponent(0.4),
            selected: .white
        )
        mirrorLayouts(on: appearance)
        return appearance
    }()

    // Install the light bar as the app-wide default. Called once at startup.
    static func installDefault() {
        UITabBar.appearance().standardAppearance = light
        UITabBar.appearance().scrollEdgeAppearance = light
    }

    // Swap every live tab bar to the dark (or light) appearance.
    static func apply(dark useDark: Bool) {
        let appearance = useDark ? dark : light
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                for bar in tabBars(in: window) {
                    bar.standardAppearance = appearance
                    bar.scrollEdgeAppearance = appearance
                    bar.setNeedsLayout()
                }
            }
        }
    }

    // MARK: - Internals

    // Builds an icons-only item appearance with the given icon colors. Titles
    // are painted clear so no label shows beneath the icon.
    private static func itemAppearance(unselected: UIColor, selected: UIColor) -> UITabBarItemAppearance {
        let item = UITabBarItemAppearance()
        item.normal.iconColor = unselected
        item.selected.iconColor = selected
        let hiddenTitle: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]
        item.normal.titleTextAttributes = hiddenTitle
        item.selected.titleTextAttributes = hiddenTitle
        return item
    }

    // Apply the stacked item appearance to the inline/compact layouts too, so
    // the styling holds across every tab-bar layout variant.
    private static func mirrorLayouts(on appearance: UITabBarAppearance) {
        appearance.inlineLayoutAppearance = appearance.stackedLayoutAppearance
        appearance.compactInlineLayoutAppearance = appearance.stackedLayoutAppearance
    }

    private static func tabBars(in view: UIView) -> [UITabBar] {
        var found: [UITabBar] = []
        if let bar = view as? UITabBar { found.append(bar) }
        for sub in view.subviews { found.append(contentsOf: tabBars(in: sub)) }
        return found
    }
}
