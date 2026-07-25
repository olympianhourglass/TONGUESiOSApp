import Foundation
import Observation

// App-wide UI language controller. Persists the user's native-language choice
// and resolves English source strings to that language at runtime. Views that
// call `L(...)` (or read `language`/`hasChosen`) inside their body re-render
// automatically when the language changes, because this is @Observable.
//
// English is the base: the keys passed to `t(_:)` ARE the English strings, so
// `.en` returns them verbatim and no English table is needed.
@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    private static let languageKey = "nativeLanguageCode"
    private static let chosenKey = "hasChosenNativeLanguage"

    // Whether the first-run native-language picker has been completed.
    private(set) var hasChosen: Bool

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.languageKey)
        self.language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .en
        self.hasChosen = UserDefaults.standard.bool(forKey: Self.chosenKey)
    }

    // Commits the picker's selection: sets the language and latches the
    // one-time "chosen" flag so the picker never shows again.
    func choose(_ lang: AppLanguage) {
        language = lang
        hasChosen = true
        UserDefaults.standard.set(true, forKey: Self.chosenKey)
    }

    // Translated string for the current language; falls back to the English
    // key when a translation is missing so nothing ever renders blank.
    func t(_ key: String) -> String {
        guard language != .en else { return key }
        return TranslationTables.tables[language]?[key] ?? key
    }
}

// Call-site shorthand: `Text(L("Continue"))`. Reads the shared Localizer, so
// using it inside a SwiftUI body establishes the observation dependency that
// re-renders the view when the language changes.
@MainActor
func L(_ key: String) -> String {
    Localizer.shared.t(key)
}

// Formatted variant for interpolated strings: the English key is a printf
// format (e.g. "%d of %d", "Did you grow up around %@?"), translated then
// filled. Locale-aware so numbers format correctly per language.
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.shared.t(key)
    return String(format: format,
                  locale: Locale(identifier: Localizer.shared.language.localeIdentifier),
                  arguments: args)
}

// DISPLAY name for a target-study language in the user's native language.
// The stored/canonical value stays English everywhere (Firestore, AI
// prompts, comparisons); this is purely for what the user reads in pickers,
// pills, and deck headers. Leans on iOS's own language-name catalog via the
// ISO code in LanguageData, so we get locale-correct names (and casing) for
// ~130 languages without hand-maintaining a table. Falls back to the English
// name whenever the system can't localize the code.
@MainActor
func localizedLanguageName(_ english: String) -> String {
    let lang = Localizer.shared.language
    guard lang != .en else { return english }
    let canonical = canonicalLanguageName(english)
    let locale = Locale(identifier: lang.localeIdentifier)
    // A bare "zh" localization collapses Mandarin and Cantonese to the same
    // word, so keep the parenthetical qualifier (itself localized).
    if canonical == "Chinese (Mandarin)" || canonical == "Chinese (Cantonese)" {
        let base = locale.localizedString(forLanguageCode: "zh") ?? "Chinese"
        let qualifier = canonical.contains("Cantonese") ? L("Cantonese") : L("Mandarin")
        return "\(base) (\(qualifier))"
    }
    guard let iso = languageISOCode(for: canonical),
          let localized = locale.localizedString(forLanguageCode: iso),
          !localized.isEmpty,
          // Some locales echo the raw code back for languages they don't know;
          // treat that as "no translation" and keep the English name.
          localized.caseInsensitiveCompare(iso) != .orderedSame
    else { return english }
    return localized
}

// DISPLAY value for a Create-New deck attribute. Languages route through the
// system localizer; content/level/dialect flow through the L() table (so
// "Words"/"Standard"/"Beginner" translate while framework names like "HSK 3"
// and proper-noun dialects fall back to English); amounts are bare numbers.
@MainActor
func localizedAttributeValue(_ value: String, for attribute: DeckAttribute) -> String {
    switch attribute {
    case .language: return localizedLanguageName(value)
    case .amount:   return value
    case .dialect, .content, .level: return L(value)
    }
}
