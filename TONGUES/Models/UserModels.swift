import Foundation

// A single language the user wants to learn, with their target dialect and
// proficiency level. Onboarding now collects an ordered list of these (the
// order reflects priority).
struct LanguagePreference: Codable, Hashable, Identifiable {
    var id = UUID()
    var language: String
    var dialect: String
    var level: String

    enum CodingKeys: String, CodingKey {
        case language, dialect, level
    }

    init(language: String, dialect: String, level: String) {
        self.language = language
        self.dialect = dialect
        self.level = level
    }
}

// A place the user wants to visit (city, country, region). Ordered list in
// OnboardingState reflects priority — top of list = top priority.
struct Destination: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String

    enum CodingKeys: String, CodingKey {
        case name
    }

    init(name: String) {
        self.name = name
    }
}

struct OnboardingAnswers: Codable, Hashable {
    var name: String?
    var languageOfInterest: String?  // Legacy single-language field (kept for backward compatibility)
    var currentLevel: String?
    var dailyTime: String?       // Legacy — no longer collected
    var motivation: String?      // Legacy — no longer collected (superseded by motivationDetail)
    var languagePreferences: [LanguagePreference]?  // Ordered by priority, max 5
    var destinations: [Destination]?  // Ordered by priority
    // New per-language motivational questions (Q4–Q7)
    var motivationDetail: String?       // What's pulling them toward the top language
    var fluencyScene: String?           // Where they picture themselves speaking fluently
    var firstUnderstand: String?        // What they'd most love to understand right now
    var heritageBackground: String?     // Whether they grew up around the language
    var interests: [String]?            // Selected profession/hobby/custom chips
    // Explicit marketing-email consent, captured on the final onboarding
    // question. Nil means never asked (distinct from false = actively
    // declined), which matters: you may re-ask someone who was never asked,
    // but not someone who said no.
    var marketingOptIn: Bool?
    let completedAt: Date
}

struct UserProfile: Codable, Hashable {
    var onboarding: OnboardingAnswers?
    var createdAt: Date?
    var updatedAt: Date?
    // Flat, top-level mirror of the primary (first) language preference, kept in
    // lock-step by UserService whenever onboarding is saved. These let a
    // companion app read the active language/dialect straight off `users/{uid}`
    // without parsing the nested onboarding array.
    var preferredLanguage: String?
    var preferredDialect: String?
    var preferredLevel: String?
    // The app-interface (native) language the user reads TONGUES in, synced from
    // Localizer so it's shared across devices / the companion app rather than
    // living only in this install's UserDefaults.
    var interfaceLanguage: String?

    // JPEG bytes of the user-uploaded profile avatar. We downscale before
    // writing so a Firestore field stays comfortably under the 1MB
    // document-size limit; the displayed avatar in the app is < 100pt so
    // a small payload is plenty.
    var avatarImage: Data?
    // Free-form description the user writes about themselves. Surfaced
    // on their own profile and on the social profile other users see
    // when they tap a friend / a deck author. Nil for users who haven't
    // written one yet. Cap softened in the service layer (no enforced
    // server-side limit; the editor view caps to ~300 chars).
    var bio: String?
}

// Read-only view of another user's profile. Used for friend lookups
// and deck-author cards — strips the onboarding answers and other
// private fields so a future Firestore rule can expose this projection
// without leaking practice habits / language goals.
struct PublicUserProfile: Codable, Hashable, Identifiable {
    var id: String { uid }
    let uid: String
    let displayName: String?
    let avatarImage: Data?
    let bio: String?
    let joinedAt: Date?
}


// Marketing-email consent. Stored at `users/{uid}/marketing/consent` — a
// SUBCOLLECTION, not the profile doc, because firestore.rules grants every
// signed-in user read access to any `users/{uid}` document (the app needs
// that to show friend names and deck authors, and Firestore can't project
// fields). Subcollections are owner-only, so the stored address is never
// readable by another user.
//
// The export tooling reads these with the Admin SDK via a collection-group
// query, which bypasses rules.
struct MarketingConsent: Codable, Hashable {
    // True = consented. False = actively declined. A MISSING document means
    // never asked — a meaningful third state, since you may re-ask someone
    // who was never asked but not someone who said no.
    var optIn: Bool = false
    var optInAt: Date? = nil
    // Snapshot of the address at consent time. Auth remains the source of
    // truth for login, but a mailing list needs a queryable copy, and the
    // address someone consented with is the one they expect to hear from.
    var email: String? = nil
    // Where consent happened ("onboarding", "settings") — the audit trail if
    // consent is ever challenged.
    var source: String? = nil
    // Apple private-relay alias (@privaterelay.appleid.com). Delivers ONLY if
    // the sending domain is registered under "Sign in with Apple for Email
    // Communication"; otherwise it hard-bounces. Flagged so the list can be
    // segmented before a send rather than after the damage.
    var isAppleRelay: Bool? = nil
}
