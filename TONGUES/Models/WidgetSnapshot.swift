import Foundation

// Shared bridge between the main app and the widget extension. The main
// app writes a `WidgetSnapshot` JSON blob into the shared App Group
// container after every Library refresh; the widget extension reads it
// from its TimelineProvider. The widget extension has no access to
// Firebase, so this is the only data crossing the process boundary.
//
// IMPORTANT — Target Membership: when this file is added to the
// `TONGUESWidget` extension target in Xcode, make sure the checkbox
// for that target is enabled in the File Inspector. The file is
// pure-Foundation so it compiles into both targets without any
// platform-specific guards.
//
// App Group identifier: `group.OlympianHourglass.TONGUES`. Mirrors the
// app's bundle ID with a `group.` prefix so it's globally unique to
// this team. Must match the .entitlements files on both targets and
// the identifier registered in the Apple Developer portal.

public enum WidgetSharedContainer {
    public static let appGroupID = "group.OlympianHourglass.TONGUES"
    public static let snapshotFileName = "widget_snapshot.json"

    /// URL of the snapshot JSON file inside the shared container. Returns
    /// nil if the App Group hasn't been provisioned yet (typical in
    /// preview / first-launch). Callers should treat nil as "skip".
    public static var snapshotURL: URL? {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        return dir.appendingPathComponent(snapshotFileName)
    }
}

// One card in the snapshot. Kept minimal: only what the widget UI
// renders + the foreign-key-ish IDs needed for the tap-to-open deep
// link. We deliberately don't serialize the full GeneratedItem since
// some of its fields aren't useful to the widget.
public struct WidgetCard: Codable, Hashable, Identifiable {
    public var id: String { cardID }
    public let cardID: String
    public let deckID: String
    public let deckTitle: String
    public let language: String
    public let dialect: String
    public let foreign: String
    public let english: String
    // Pronunciation guide (pinyin / romaji / IPA / etc.). Optional
    // because Latin-script languages typically omit it. The lock screen
    // widget renders this between the foreign line and the English
    // translation when present.
    public let transliteration: String?
    // FSRS forgetting risk ∈ [0, 1] at the moment the snapshot was
    // written. Higher = more likely to be forgotten now. Persisted so
    // the widget can re-sort offline.
    public let forgettingRisk: Double
    // Mirrors the parent deck's contentType ("Words", "Phrases",
    // "Sentences"). The widget filters on this in language/deck modes,
    // where phrases and sentences are explicitly excluded — only word
    // cards cycle.
    public let contentType: String

    public init(
        cardID: String,
        deckID: String,
        deckTitle: String,
        language: String,
        dialect: String,
        foreign: String,
        english: String,
        transliteration: String? = nil,
        forgettingRisk: Double,
        contentType: String
    ) {
        self.cardID = cardID
        self.deckID = deckID
        self.deckTitle = deckTitle
        self.language = language
        self.dialect = dialect
        self.foreign = foreign
        self.english = english
        self.transliteration = transliteration
        self.forgettingRisk = forgettingRisk
        self.contentType = contentType
    }

    // Custom decoder so older snapshot blobs (no `transliteration` key)
    // continue to decode after this field landed — without it, the
    // widget extension would briefly show "Add a deck" placeholders
    // until the main app rewrites the snapshot.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cardID         = try c.decode(String.self, forKey: .cardID)
        self.deckID         = try c.decode(String.self, forKey: .deckID)
        self.deckTitle      = try c.decode(String.self, forKey: .deckTitle)
        self.language       = try c.decode(String.self, forKey: .language)
        self.dialect        = try c.decode(String.self, forKey: .dialect)
        self.foreign        = try c.decode(String.self, forKey: .foreign)
        self.english        = try c.decode(String.self, forKey: .english)
        self.transliteration = try c.decodeIfPresent(String.self, forKey: .transliteration)
        self.forgettingRisk = try c.decode(Double.self, forKey: .forgettingRisk)
        self.contentType    = try c.decode(String.self, forKey: .contentType)
    }
}

// Lightweight deck descriptor used by the widget's configuration intent
// to populate its picker. Title + language give the user enough info to
// disambiguate; the cards themselves are looked up from
// `WidgetSnapshot.cards` by deckID.
public struct WidgetDeckRef: Codable, Hashable, Identifiable {
    public var id: String { deckID }
    public let deckID: String
    public let title: String
    public let language: String

    public init(deckID: String, title: String, language: String) {
        self.deckID = deckID
        self.title = title
        self.language = language
    }
}

// What the main app writes to the App Group container after each
// LibraryViewModel.loadDecks. Versioned so future schema changes don't
// crash the widget when the user upgrades the app but the widget
// hasn't reloaded yet.
public struct WidgetSnapshot: Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    // Every card across every deck, pre-ranked by descending
    // forgettingRisk. The widget reads from this array via the
    // configured filter mode.
    public let cards: [WidgetCard]
    // Lightweight deck list for the configuration picker. Sorted by
    // title ascending so the picker reads alphabetically.
    public let decks: [WidgetDeckRef]
    // Unique language strings (canonical form) the user has decks for.
    // Sorted alphabetically. Drives the "By Language" picker.
    public let languages: [String]

    public init(
        generatedAt: Date,
        cards: [WidgetCard],
        decks: [WidgetDeckRef],
        languages: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.cards = cards
        self.decks = decks
        self.languages = languages
    }
}

// Preferred language for the lock screen widget. Stored in the App
// Group's UserDefaults so the in-app picker and the widget extension
// read the same value. The lock screen widget uses a
// `StaticConfiguration` (no Edit Widget panel for language), so this
// store is the only way to change it — exactly what the user asked
// for. Nil means "auto" → fall back to the first language in the
// snapshot at render time.
public enum WidgetLockScreenLanguageStore {
    private static let key = "widget.lockScreenLanguage"

    public static func read() -> String? {
        UserDefaults(suiteName: WidgetSharedContainer.appGroupID)?
            .string(forKey: key)
    }

    public static func write(_ language: String?) {
        let defaults = UserDefaults(suiteName: WidgetSharedContainer.appGroupID)
        if let language {
            defaults?.set(language, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }
}

// Per-bucket shuffle offset, bumped by the in-widget shuffle button
// AppIntent. The provider adds it to the slot index when picking a card
// so successive taps advance through the pool. Lives in the App Group
// UserDefaults so the intent (running in the widget extension) and the
// provider (also in the extension) read the same value.
//
// Home widget keys include the source ID (e.g. "home.fsrs",
// "home.lang:Spanish", "home.deck:abc123") so two widgets showing
// different sources shuffle independently. Two widgets showing the
// *same* source still share an offset, which is acceptable — they're
// displaying the same pool and presumably want to stay in sync.
public enum WidgetShuffleOffsetStore {
    public enum Kind {
        case home(sourceID: String)
        case lockScreen

        var storageKey: String {
            switch self {
            case .home(let sourceID): return "widget.shuffleOffset.home.\(sourceID)"
            case .lockScreen:         return "widget.shuffleOffset.lockScreen"
            }
        }
    }

    public static func read(_ kind: Kind) -> Int {
        UserDefaults(suiteName: WidgetSharedContainer.appGroupID)?
            .integer(forKey: kind.storageKey) ?? 0
    }

    public static func advance(_ kind: Kind, by amount: Int = 1) {
        guard let defaults = UserDefaults(suiteName: WidgetSharedContainer.appGroupID) else {
            return
        }
        let current = defaults.integer(forKey: kind.storageKey)
        defaults.set(current &+ max(1, amount), forKey: kind.storageKey)
    }
}

// User-selectable background color for the widget. Stored separately
// from the snapshot in the App Group's UserDefaults so the user can
// recolor without waiting on a full snapshot rewrite. Hex strings are
// uppercase, no `#`, six chars (e.g. "4E5B65") so they cross the
// bridge as plain `String`.
public enum WidgetBackgroundColorStore {
    public static let palette: [String] = [
        "4E5B65", "000000", "FF2C02", "3C0F06", "A5A597"
    ]
    public static let defaultHex = palette[0]
    private static let key = "widget.backgroundHex"

    public static func read() -> String {
        guard let defaults = UserDefaults(suiteName: WidgetSharedContainer.appGroupID),
              let hex = defaults.string(forKey: key),
              palette.contains(hex) else {
            return defaultHex
        }
        return hex
    }

    public static func write(_ hex: String) {
        guard palette.contains(hex),
              let defaults = UserDefaults(suiteName: WidgetSharedContainer.appGroupID) else {
            return
        }
        defaults.set(hex, forKey: key)
    }
}

// Helpers used by both sides of the bridge to read/write the snapshot
// without re-implementing JSON ceremony. Failures are non-fatal — the
// widget falls back to placeholder content, the writer logs and moves
// on so a snapshot bug never crashes the main app.
public enum WidgetSnapshotIO {
    public static func read() -> WidgetSnapshot? {
        guard let url = WidgetSharedContainer.snapshotURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WidgetSnapshot.self, from: data)
        } catch {
            print("WidgetSnapshotIO read failed: \(error)")
            return nil
        }
    }

    @discardableResult
    public static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = WidgetSharedContainer.snapshotURL else {
            print("WidgetSnapshotIO write skipped: App Group container unavailable")
            return false
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            print("WidgetSnapshotIO write failed: \(error)")
            return false
        }
    }
}
