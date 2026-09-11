import SwiftUI

// App-lifetime home for the audio listening session. Presenting a session
// used to be a `fullScreenCover` owned by whichever screen started it, so
// pulling the cover down tore the whole thing out — playback state and all.
//
// To keep audio going after a pull-down (Apple Music-style), the session now
// lives at the app root: `ContentView` renders a single `ListenSessionView`
// whenever `deck` is non-nil, and the pull-down flips `isMinimized` rather
// than dismissing. Because the view stays mounted across that transition, all
// of its playback `@State` survives and the audio never stops.
@MainActor
@Observable
final class ListenSessionHost {
    static let shared = ListenSessionHost()
    private init() {}

    // The deck whose session is active. Non-nil for the entire lifetime of a
    // session — whether it's showing full-screen or collapsed to the mini-bar.
    var deck: DeckDocument?

    // True while the session is collapsed to the floating mini-bar above the
    // tab bar. The full player is off-screen but the view is still mounted, so
    // playback continues.
    var isMinimized = false

    // Set for the brief window while the mini-bar is dissolving away via the
    // Liquid Glass materialize transition (swipe-left to dismiss). During it the
    // mini-bar is removed from the hierarchy so the glass melts out, and the
    // Study tab's Create New Deck button morphs back to full size — then `end()`
    // stops playback and tears the session down.
    var isDismissing = false

    // Set by full-bleed screens that hide the tab bar (e.g. StatisticsView) so
    // the mini-bar disappears there while the session keeps playing — the
    // ListenSessionView stays mounted, only its bar is withheld.
    var hideMiniBar = false

    // The Study tab's Create New Deck button frame in global space, published
    // by StudyView so the mini-bar can match its height and sit 8pt to its
    // left. `.zero` until StudyView has laid out at least once.
    var createButtonFrame: CGRect = .zero

    // Whether the Create New Deck button is actually on screen (Study home with
    // an empty nav stack). False once a detail page is pushed over it, so the
    // mini-bar reverts to the full default width there instead of leaving a gap
    // for a button that's no longer visible.
    var createButtonVisible = false

    private var minimizeSpring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }

    func present(_ deck: DeckDocument) {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.86)) {
            self.deck = deck
            isMinimized = false
        }
    }

    func minimize() {
        withAnimation(minimizeSpring) { isMinimized = true }
    }

    func expand() {
        withAnimation(minimizeSpring) { isMinimized = false }
    }

    // Swipe-left dismissal: melt the mini-bar out with the Liquid Glass
    // materialize transition (and morph the Create button back), then end the
    // session once the dissolve has played.
    func dismissMiniBar() {
        guard deck != nil, isMinimized, !isDismissing else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            isDismissing = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            end()
        }
    }

    func end() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            deck = nil
            isMinimized = false
            isDismissing = false
        }
    }
}
