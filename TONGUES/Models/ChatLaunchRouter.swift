import Foundation
import Observation

// A one-shot hand-off from the curriculum surface (PlanView) to the Chat
// tab. PlanView and ChatView own separate ChatViewModel instances, so a
// "start this conversation lesson" tap can't call the chat directly —
// instead it drops a request here and flips the tab (AppTabRouter). ChatView
// observes `pending`, consumes it (switches language + opens the scenario),
// and clears it. Mirrors the QuickActionRouter / WidgetDeepLinkRouter pattern.
@MainActor
@Observable
final class ChatLaunchRouter {
    static let shared = ChatLaunchRouter()
    private init() {}

    var pending: ChatScenarioLaunch?

    func request(_ launch: ChatScenarioLaunch) {
        pending = launch
    }
}

// The payload for a curriculum-initiated conversation: which language to
// switch the chat into, and the scenario the AI tutor should open with.
struct ChatScenarioLaunch: Equatable {
    let language: String
    let dialect: String
    let level: String
    let title: String
    let prompt: String
}
