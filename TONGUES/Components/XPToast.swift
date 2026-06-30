import SwiftUI
import Observation

// Global, fire-and-forget XP toast system. Anywhere in the app can call
// `XPToastCenter.shared.queue(grant)` (or `enqueue(_:)` with multiple at
// once); the root view's `.xpToastOverlay()` modifier observes the
// coordinator and pops toasts one at a time from the queue.
@Observable
@MainActor
final class XPToastCenter {
    static let shared = XPToastCenter()
    private init() {}

    // Display window for a single toast. Includes both the slide-in and
    // slide-out animation so back-to-back queues feel snappy.
    private static let displayDuration: TimeInterval = 1.6

    private(set) var currentToast: ToastItem? = nil
    private var queue: [ToastItem] = []
    private var presenterTask: Task<Void, Never>? = nil

    struct ToastItem: Identifiable, Equatable {
        let id = UUID()
        let amount: Int
        let reason: String
    }

    func queue(_ grant: XPGrant) {
        enqueue([grant])
    }

    func enqueue(_ grants: [XPGrant]) {
        guard !grants.isEmpty else { return }
        for g in grants {
            queue.append(ToastItem(amount: g.amount, reason: g.reason))
        }
        startPresentingIfNeeded()
    }

    private func startPresentingIfNeeded() {
        guard presenterTask == nil else { return }
        presenterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                self.currentToast = next
                try? await Task.sleep(for: .seconds(Self.displayDuration))
                self.currentToast = nil
                // Brief beat between toasts so the eye can register the
                // change rather than seeing one snap into another.
                try? await Task.sleep(for: .milliseconds(180))
            }
            self.presenterTask = nil
        }
    }
}

// Capsule styling deliberately mirrors `SessionCompleteToast` so XP
// awards feel like part of the same notification family — same
// black capsule, same shadow, same horizontal padding.
struct XPToastView: View {
    let toast: XPToastCenter.ToastItem

    var body: some View {
        HStack(spacing: 8) {
            Text("+\(toast.amount) XP")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Text("·")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
            Text(toast.reason)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
}

extension View {
    // Drop on a top-level view (root or each tab) to enable the XP toast
    // overlay. Living at the root means toasts persist even when the
    // user navigates to a different screen while one is still showing.
    func xpToastOverlay() -> some View {
        modifier(XPToastOverlayModifier())
    }
}

private struct XPToastOverlayModifier: ViewModifier {
    @State private var center = XPToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.currentToast {
                    XPToastView(toast: toast)
                        .padding(.bottom, 110)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: center.currentToast)
    }
}
