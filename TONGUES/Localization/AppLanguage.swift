import Foundation

// The native (UI) languages TONGUES can present itself in. English is the
// base — its strings are the literal keys used everywhere in code, so `.en`
// needs no translation table. The other eight are Apple's best-localized
// tier and each carries a full translation table (see TranslationTables).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case en
    case es
    case fr
    case de
    case it
    case ptBR
    case ja
    case zhHans
    case ko

    var id: String { rawValue }

    // BCP-47 identifier used for the SwiftUI `\.locale` environment (drives
    // date/number formatting and system-vended strings).
    var localeIdentifier: String {
        switch self {
        case .en:     return "en"
        case .es:     return "es"
        case .fr:     return "fr"
        case .de:     return "de"
        case .it:     return "it"
        case .ptBR:   return "pt-BR"
        case .ja:     return "ja"
        case .zhHans: return "zh-Hans"
        case .ko:     return "ko"
        }
    }

    // The language's own name — what the picker shows as the primary label.
    var endonym: String {
        switch self {
        case .en:     return "English"
        case .es:     return "Español"
        case .fr:     return "Français"
        case .de:     return "Deutsch"
        case .it:     return "Italiano"
        case .ptBR:   return "Português"
        case .ja:     return "日本語"
        case .zhHans: return "中文"
        case .ko:     return "한국어"
        }
    }

    // English name — the picker's secondary label, always legible.
    var englishName: String {
        switch self {
        case .en:     return "English"
        case .es:     return "Spanish"
        case .fr:     return "French"
        case .de:     return "German"
        case .it:     return "Italian"
        case .ptBR:   return "Portuguese (Brazil)"
        case .ja:     return "Japanese"
        case .zhHans: return "Chinese (Simplified)"
        case .ko:     return "Korean"
        }
    }

    var flag: String {
        switch self {
        case .en:     return "🇬🇧"
        case .es:     return "🇪🇸"
        case .fr:     return "🇫🇷"
        case .de:     return "🇩🇪"
        case .it:     return "🇮🇹"
        case .ptBR:   return "🇧🇷"
        case .ja:     return "🇯🇵"
        case .zhHans: return "🇨🇳"
        case .ko:     return "🇰🇷"
        }
    }

    // Canonical language name that `appleSpeechLocale(for:)` recognizes, so
    // the native-language "read aloud" audio picks the right Apple TTS voice.
    var speechLanguageName: String {
        switch self {
        case .en:     return "English"
        case .es:     return "Spanish"
        case .fr:     return "French"
        case .de:     return "German"
        case .it:     return "Italian"
        case .ptBR:   return "Portuguese"
        case .ja:     return "Japanese"
        case .zhHans: return "Chinese"
        case .ko:     return "Korean"
        }
    }

    // Whether this language is written in Latin script. Used by heuristics
    // that pre-filter "is this text the user's native language?" (e.g. the
    // tutor's meta-vs-practice classifier).
    var usesLatinScript: Bool {
        switch self {
        case .en, .es, .fr, .de, .it, .ptBR: return true
        case .ja, .zhHans, .ko:              return false
        }
    }

    // Thread-safe snapshot of the user's chosen native language, read from
    // the same persisted key Localizer writes. Safe to call from background
    // service code (generation runs off the main actor), unlike the
    // @MainActor Localizer.shared. Falls back to English.
    static var currentNative: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "nativeLanguageCode")
        return raw.flatMap(AppLanguage.init(rawValue:)) ?? .en
    }

    // The name of this language when written for a Claude prompt, so
    // AI-generated explanatory text can be produced in the user's language.
    var promptName: String {
        switch self {
        case .en:     return "English"
        case .es:     return "Spanish"
        case .fr:     return "French"
        case .de:     return "German"
        case .it:     return "Italian"
        case .ptBR:   return "Brazilian Portuguese"
        case .ja:     return "Japanese"
        case .zhHans: return "Simplified Chinese"
        case .ko:     return "Korean"
        }
    }
}
