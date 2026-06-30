import WidgetKit
import SwiftUI

// The visible widget. Bound to the provider + entry view above.
// `AppIntentConfiguration` plugs the configuration intent into the
// system widget editor so the user can pick mode + language/deck
// without leaving the wallpaper editor.
struct WordCycleWidget: Widget {
    let kind: String = "WordCycleWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WordCycleConfigurationIntent.self,
            provider: WordCycleProvider()
        ) { entry in
            WordCycleEntryView(entry: entry)
        }
        .configurationDisplayName("Word Cycle")
        .description("Rotates through flashcards you're most likely to forget.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // Keep content visible in StandBy / always-on without the
        // luminance dim, since the slate already reads well in low
        // light.
        .contentMarginsDisabled()
    }
}
