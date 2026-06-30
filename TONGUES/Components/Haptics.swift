import UIKit

// Pre-prepared singleton generators so taps fire instantly. Recreating
// `UIImpactFeedbackGenerator` on every call (the previous pattern) leaves
// the haptic engine cold, producing a noticeable delay on the first tap of
// any screen. Each call here re-`prepare()`s after firing to keep the next
// tap warm.
enum Haptics {
    nonisolated(unsafe) private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    nonisolated(unsafe) private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    nonisolated(unsafe) private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// Subtle tap feedback for routine button presses.
    static func light() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    /// Slightly heavier tap, e.g. for a primary commit action.
    static func medium() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    /// Two-beat success pulse for completion events (e.g. saved to deck).
    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}
