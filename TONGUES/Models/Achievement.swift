import Foundation

// A single unlockable achievement. Every achievement is a PURE predicate over
// `UserXPState`: its progress and unlocked state are computed straight from the
// persisted counters, so there's one source of truth and no separate tracking
// to keep in sync. `XPService.commit` calls `reconcile(into:)` after every
// state change to record newly-satisfied achievements into
// `UserXPState.unlockedAchievements` (deduped like `awardedStreakMilestones`).
struct Achievement: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case audio
        case artifacts
        case milestones

        var id: String { rawValue }

        // Section header shown above each group in the Achievements tab.
        var title: String {
            switch self {
            case .audio:      return "Listening"
            case .artifacts:  return "Creating"
            case .milestones: return "Milestones"
            }
        }
    }

    let id: String
    let title: String
    let detail: String          // one-line "how to earn it"
    let systemImage: String     // SF Symbol
    let category: Category
    let target: Int             // goal in `unitSuffix` units; 1 for boolean ones
    let unitSuffix: String      // "", " min", " days", " XP", …
    // Current progress toward `target`, read from persisted state.
    let progress: (UserXPState) -> Int

    // Progress clamped to the target, for display ("X / target").
    func displayCurrent(_ state: UserXPState) -> Int {
        min(progress(state), target)
    }

    func isUnlocked(_ state: UserXPState) -> Bool {
        progress(state) >= target
    }
}

extension Achievement {
    // The full catalog, in display order within each category.
    static let all: [Achievement] = [
        // MARK: Listening (audio)
        Achievement(
            id: "ears-on",
            title: "Ears On",
            detail: "Finish your first listening session.",
            systemImage: "ear",
            category: .audio,
            target: 1,
            unitSuffix: "",
            progress: { $0.audioSessionCount }
        ),
        Achievement(
            id: "deep-listener",
            title: "Deep Listener",
            detail: "Listen for 5 hours in total.",
            systemImage: "headphones",
            category: .audio,
            target: 300,
            unitSuffix: " min",
            progress: { Int($0.listenSecondsTotal / 60) }
        ),
        Achievement(
            id: "ambient-soul",
            title: "Ambient Soul",
            detail: "Listen with an ambient track playing.",
            systemImage: "waveform",
            category: .audio,
            target: 1,
            unitSuffix: "",
            progress: { $0.listenedWithAmbient ? 1 : 0 }
        ),
        Achievement(
            id: "night-owl",
            title: "Night Owl",
            detail: "Listen for 30 minutes in a single session.",
            systemImage: "moon.stars",
            category: .audio,
            target: 30,
            unitSuffix: " min",
            progress: { Int($0.longestListenSeconds / 60) }
        ),

        // MARK: Creating (artifacts)
        Achievement(
            id: "first-draft",
            title: "First Draft",
            detail: "Generate your first artifact.",
            systemImage: "sparkles",
            category: .artifacts,
            target: 1,
            unitSuffix: "",
            progress: { $0.artifactSessionCount }
        ),
        Achievement(
            id: "full-anthology",
            title: "Full Anthology",
            detail: "Generate a story, conversation, news article, song, poem, and joke.",
            systemImage: "books.vertical",
            category: .artifacts,
            target: 6,
            unitSuffix: "",
            progress: { $0.generatedArtifactKinds.count }
        ),
        Achievement(
            id: "prolific",
            title: "Prolific",
            detail: "Generate 50 artifacts.",
            systemImage: "doc.on.doc",
            category: .artifacts,
            target: 50,
            unitSuffix: "",
            progress: { $0.artifactSessionCount }
        ),
        Achievement(
            id: "close-reader",
            title: "Close Reader",
            detail: "Answer 25 artifact comprehension questions correctly.",
            systemImage: "text.magnifyingglass",
            category: .artifacts,
            target: 25,
            unitSuffix: "",
            progress: { $0.correctComprehensionCount }
        ),
        Achievement(
            id: "genre-hopper",
            title: "Genre-Hopper",
            detail: "Generate artifacts in 10 different vibes.",
            systemImage: "theatermasks",
            category: .artifacts,
            target: 10,
            unitSuffix: "",
            progress: { $0.generatedArtifactVibes.count }
        ),

        // MARK: Milestones (general)
        Achievement(
            id: "first-flame",
            title: "First Flame",
            detail: "Reach a 3-day streak.",
            systemImage: "flame",
            category: .milestones,
            target: 3,
            unitSuffix: " days",
            progress: { $0.bestStreak }
        ),
        Achievement(
            id: "kept-the-fire",
            title: "Kept the Fire",
            detail: "Reach a 30-day streak.",
            systemImage: "flame.fill",
            category: .milestones,
            target: 30,
            unitSuffix: " days",
            progress: { $0.bestStreak }
        ),
        Achievement(
            id: "year-of-tongues",
            title: "Year of Tongues",
            detail: "Reach a 365-day streak.",
            systemImage: "crown",
            category: .milestones,
            target: 365,
            unitSuffix: " days",
            progress: { $0.bestStreak }
        ),
        Achievement(
            id: "dawn-patrol",
            title: "Dawn Patrol",
            detail: "Study before 8 AM.",
            systemImage: "sunrise",
            category: .milestones,
            target: 1,
            unitSuffix: "",
            progress: { $0.studiedBefore8AM ? 1 : 0 }
        ),
        Achievement(
            id: "scholar",
            title: "Scholar",
            detail: "Earn 10,000 XP.",
            systemImage: "graduationcap",
            category: .milestones,
            target: 10_000,
            unitSuffix: " XP",
            progress: { $0.total }
        ),
        Achievement(
            id: "polyglot",
            title: "Polyglot",
            detail: "Study 3 or more languages.",
            systemImage: "globe",
            category: .milestones,
            target: 3,
            unitSuffix: "",
            progress: { $0.seenLanguages.count }
        )
    ]

    static func inCategory(_ category: Category) -> [Achievement] {
        all.filter { $0.category == category }
    }

    // Appends the id of every not-yet-unlocked achievement whose predicate is
    // now satisfied, and returns those newly-unlocked achievements so the
    // caller can surface a toast. Mirrors the dedupe pattern used for streak
    // milestones — an id is only ever appended (and returned) once.
    @discardableResult
    static func reconcile(into state: inout UserXPState) -> [Achievement] {
        var newlyUnlocked: [Achievement] = []
        for achievement in all where !state.unlockedAchievements.contains(achievement.id) {
            if achievement.isUnlocked(state) {
                state.unlockedAchievements.append(achievement.id)
                newlyUnlocked.append(achievement)
            }
        }
        return newlyUnlocked
    }
}
