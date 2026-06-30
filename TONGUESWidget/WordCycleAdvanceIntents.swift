import AppIntents
import WidgetKit

// AppIntents wired to the shuffle button inside each widget's body.
// Each tap bumps a per-bucket shuffle offset in App Group UserDefaults
// and reloads only that widget kind. The provider folds the offset into
// the slot index when picking a card, so the user lands on a different
// item in the same source bucket without disturbing widgets configured
// to other sources.

struct AdvanceWordCycleIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle word"
    static var description = IntentDescription(
        "Show a different word from this widget's source."
    )
    static var isDiscoverable = false

    // Source bucket the tapped widget is bound to ("fsrs",
    // "lang:Spanish", "deck:<id>", …). Built from the configuration
    // intent's source and threaded through the entry so the button knows
    // which bucket to advance — without this the offset would be global
    // to every home widget on the screen.
    @Parameter(title: "Source identifier")
    var sourceID: String

    init() { sourceID = "fsrs" }
    init(sourceID: String) { self.sourceID = sourceID }

    func perform() async throws -> some IntentResult {
        WidgetShuffleOffsetStore.advance(.home(sourceID: sourceID))
        WidgetCenter.shared.reloadTimelines(ofKind: "WordCycleWidget")
        return .result()
    }
}

struct AdvanceLockScreenWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle word"
    static var description = IntentDescription(
        "Show a different word from your chosen language."
    )
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetShuffleOffsetStore.advance(.lockScreen)
        WidgetCenter.shared.reloadTimelines(ofKind: "LockScreenWordWidget")
        return .result()
    }
}
