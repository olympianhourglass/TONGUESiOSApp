import Foundation
import UIKit

enum AppTab: Hashable {
    case explore, study, library, chat
}

// Tabs that paint a dark backdrop behind the status bar and therefore
// need white-content status bar text. Centralised here so the
// hosting-controller side (which has to express this in UIKit terms)
// and any future SwiftUI surface read the same source of truth.
extension AppTab {
    var needsLightStatusBarContent: Bool {
        switch self {
        case .study, .library: return true
        case .explore, .chat:  return false
        }
    }
}

// Shared current-tab tracker + status-bar driver.
//
// `.preferredColorScheme` and `window.overrideUserInterfaceStyle`
// both lost to the WindowGroup's `.preferredColorScheme(.light)` —
// SwiftUI re-applies its trait collection on the hosting controller
// every frame, which is what the status bar reads. The reliable fix
// is to override the hosting controller's `preferredStatusBarStyle`
// getter directly via a runtime subclass; see StatusBarStyleSwap for
// the gritty objc-runtime details.
//
// This router just owns the current tab + tells the swap to
// re-evaluate the bar on every change.
@MainActor
@Observable
final class AppTabRouter {
    static let shared = AppTabRouter()
    private init() {}

    var current: AppTab = .study {
        didSet { applyStatusBarStyle() }
    }

    func applyStatusBarStyle() {
        StatusBarStyleSwap.installAndRefresh()
    }
}
