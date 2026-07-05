import Foundation
import FirebaseAuth
import FirebaseFirestore

enum UserService {
    private static let db = Firestore.firestore()
    private static let collection = "users"

    static var currentUID: String? { Auth.auth().currentUser?.uid }

    // MARK: - Local cache

    // On-device mirror of the user's onboarding answers (which carry
    // their language preferences). Reading Firestore on cold start takes
    // long enough to visibly flash generic defaults in the UI — the
    // Create New sheet, for one — so we persist the answers to
    // UserDefaults and seed instantly from there, then reconcile with the
    // authoritative Firestore copy when it lands. Keyed per-UID so a
    // second account on the same device never reads the first's cache.
    private static let onboardingCachePrefix = "cachedOnboardingAnswers_"

    private static func onboardingCacheKey(for uid: String) -> String {
        onboardingCachePrefix + uid
    }

    // Synchronous read of the cached onboarding answers for the signed-in
    // user. Returns nil when signed-out or nothing has been cached yet.
    static func cachedOnboarding() -> OnboardingAnswers? {
        guard let uid = currentUID,
              let data = UserDefaults.standard.data(forKey: onboardingCacheKey(for: uid))
        else { return nil }
        return try? JSONDecoder().decode(OnboardingAnswers.self, from: data)
    }

    private static func cacheOnboarding(_ answers: OnboardingAnswers?) {
        guard let uid = currentUID else { return }
        let key = onboardingCacheKey(for: uid)
        guard let answers, let data = try? JSONEncoder().encode(answers) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    // Clears the cached answers for a specific user. Called when wiping
    // an account so a re-signup on the same device starts clean.
    static func clearOnboardingCache(for uid: String) {
        UserDefaults.standard.removeObject(forKey: onboardingCacheKey(for: uid))
    }

    static func userDoc(uid: String) -> DocumentReference {
        db.collection(collection).document(uid)
    }

    /// Saves the onboarding answers onto the `users/{uid}` document.
    /// Uses `merge: true` so we don't clobber any other profile fields.
    /// One read (existence check) + one write — the read is only required on first save to set `createdAt`.
    static func saveOnboarding(_ answers: OnboardingAnswers) async throws {
        guard let uid = currentUID else { throw AuthError.notAuthenticated }
        let ref = userDoc(uid: uid)

        let encoder = Firestore.Encoder()
        let answersData = try encoder.encode(answers)

        var payload: [String: Any] = [
            "onboarding": answersData,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        // Only set createdAt if the document doesn't already exist (preserve first-seen time).
        let snapshot = try await ref.getDocument()
        if !snapshot.exists {
            payload["createdAt"] = FieldValue.serverTimestamp()
        }

        try await ref.setData(payload, merge: true)
        // Keep the on-device cache in lock-step so the next cold start
        // seeds the freshly-saved language preferences instantly.
        cacheOnboarding(answers)
    }

    static func fetchProfile() async throws -> UserProfile? {
        guard let uid = currentUID else { throw AuthError.notAuthenticated }
        let snapshot = try await userDoc(uid: uid).getDocument()
        guard snapshot.exists else { return nil }
        let profile = try snapshot.data(as: UserProfile.self)
        // Refresh the local cache from the authoritative copy.
        cacheOnboarding(profile.onboarding)
        return profile
    }

    // Writes only the bio field on the user document. Empty / blank
    // strings are stored as nil so the field disappears from the doc
    // entirely rather than persisting a zero-length value. Uses
    // `merge: true` so onboarding answers, avatar bytes, and
    // timestamps stay untouched.
    static func saveBio(_ bio: String?) async throws {
        guard let uid = currentUID else { throw AuthError.notAuthenticated }
        let trimmed = bio?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = (trimmed?.isEmpty == false) ? trimmed! : FieldValue.delete()
        try await userDoc(uid: uid).setData(
            [
                "bio": value,
                "updatedAt": FieldValue.serverTimestamp()
            ],
            merge: true
        )
    }

    // Fetches the read-only projection of another user's profile.
    // Returns nil when the document doesn't exist or the user has no
    // public-facing fields set. Used by friend lookups and deck-author
    // cards — the projection intentionally drops onboarding answers
    // and other private state.
    static func fetchPublicProfile(uid: String) async throws -> PublicUserProfile? {
        let snapshot = try await userDoc(uid: uid).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        let displayName = data["displayName"] as? String
            ?? (data["onboarding"] as? [String: Any])?["name"] as? String
        let avatar = data["avatarImage"] as? Data
        let bio = data["bio"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        return PublicUserProfile(
            uid: uid,
            displayName: displayName,
            avatarImage: avatar,
            bio: bio,
            joinedAt: createdAt
        )
    }

    // Writes only the avatar field on the user document. Uses `merge:
    // true` so onboarding answers and timestamps stay untouched. Caller
    // is responsible for downscaling/compressing the image — this helper
    // is intentionally byte-agnostic so it'll work for any future image
    // format without re-encoding here.
    static func saveAvatarImage(_ data: Data) async throws {
        guard let uid = currentUID else { throw AuthError.notAuthenticated }
        try await userDoc(uid: uid).setData(
            [
                "avatarImage": data,
                "updatedAt": FieldValue.serverTimestamp()
            ],
            merge: true
        )
    }

    // Appends a single language preference to the user's onboarding
    // answers. Used by the Explore tab's "Languages Based on Where You
    // Are" row so tapping Add Language behaves the same as picking it
    // during onboarding. No-ops if the language is already saved.
    static func addLanguagePreference(_ pref: LanguagePreference) async throws {
        guard var profile = try await fetchProfile(), var answers = profile.onboarding else { return }
        var prefs = answers.languagePreferences ?? []
        if prefs.contains(where: { $0.language.lowercased() == pref.language.lowercased() }) {
            return
        }
        // Tier-cap defense in depth — onboarding has its own UI gate,
        // but Explore's "Languages near you" calls into this method
        // directly. Throwing `SubscriptionError.languageCapExceeded`
        // lets call sites surface the paywall.
        try await SubscriptionService.shared.ensureLanguageSlotAvailable(currentCount: prefs.count)
        prefs.append(pref)
        answers.languagePreferences = prefs
        // Mirror the legacy single-language field so older code paths
        // (e.g. CreateDeckSheet's first-preference seed) still pick this
        // language up if it ends up first.
        if answers.languageOfInterest == nil {
            answers.languageOfInterest = pref.language
        }
        profile.onboarding = answers
        try await saveOnboarding(answers)
    }

    // Wipes every Firestore document scoped to the given UID — decks,
    // study sessions, card schedules, XP state, and the parent user
    // doc. Called by AuthService.deleteAccount before deleting the auth
    // user. Batches subcollection deletes in chunks of 400 to stay
    // safely under Firestore's 500-ops-per-batch limit.
    static func deleteAllUserData(uid: String) async throws {
        let userRef = userDoc(uid: uid)
        // Every subcollection the app ever writes under `users/{uid}`.
        // Keep this list in sync with FirebaseDeckService's schema
        // comment + XPService's docRef path.
        let subcollections = [
            "decks", "studySessions", "cardSchedules", "xp",
            // Curriculum-agent collections (learner models are derived,
            // curricula are user-confirmed plans — both user-scoped).
            "learnerModels", "curricula"
        ]

        for name in subcollections {
            let snapshot = try await userRef.collection(name).getDocuments()
            var batch = db.batch()
            var pending = 0
            for doc in snapshot.documents {
                batch.deleteDocument(doc.reference)
                pending += 1
                if pending >= 400 {
                    try await batch.commit()
                    batch = db.batch()
                    pending = 0
                }
            }
            if pending > 0 {
                try await batch.commit()
            }
        }

        // Delete the parent user doc last so the profile blob — which
        // gates onboarding routing on the next launch — disappears only
        // after the data it summarizes is already gone.
        try await userRef.delete()

        // Drop the on-device onboarding cache too so a re-signup on this
        // device doesn't inherit the deleted account's language prefs.
        clearOnboardingCache(for: uid)
    }
}
