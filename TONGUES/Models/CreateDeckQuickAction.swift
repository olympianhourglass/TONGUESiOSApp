import Foundation

// A shortcut into a specific Create New Deck tab. Shared by the Study
// tab's long-press quick-action menu and the app-icon Home Screen
// shortcuts so both map to the same destinations.
enum CreateDeckQuickAction: String {
    case direct
    case conversation
    case camera

    // Matches the app-icon shortcut item types declared in Info.plist.
    init?(shortcutType: String) {
        switch shortcutType {
        case "com.tongues.shortcut.direct":       self = .direct
        case "com.tongues.shortcut.conversation": self = .conversation
        case "com.tongues.shortcut.camera":       self = .camera
        default: return nil
        }
    }

    // Page index inside CreateDeckSheet's TabView:
    // 0 Generate · 1 Camera · 2 Direct · 3 Song/Video · 4 Large Body Text.
    var page: Int {
        switch self {
        case .camera:                 return 1
        case .direct, .conversation:  return 2
        }
    }

    // Direct + Conversation share the Direct tab; only Conversation opens
    // it in conversation mode.
    var startsConversation: Bool { self == .conversation }
}

// Routes an app-icon Home Screen shortcut into the running app. The scene
// delegate sets `pending`; ContentView flips to the Study tab and
// StudyView consumes it to open the Create New Deck sheet on the right
// page, then clears it.
@MainActor
@Observable
final class QuickActionRouter {
    static let shared = QuickActionRouter()
    private init() {}

    var pending: CreateDeckQuickAction?
}
