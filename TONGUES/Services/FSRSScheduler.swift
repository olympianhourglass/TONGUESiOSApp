import Foundation

/// Per-deck urgency snapshot used by the Study tab to surface decks the user is most
/// likely to forget. Score is sum-of-per-card forgetting risk — higher = more urgent.
struct DeckUrgency: Hashable {
    let score: Double
    let dueCount: Int
    let newCount: Int
    /// Cards whose FSRS stability has crossed the "learned" threshold —
    /// i.e. the user has answered them correctly enough times that the
    /// algorithm projects at least a week of retention. A subsequent
    /// `.again` lapse drops stability sharply (see `FSRSScheduler.apply`)
    /// so the count contracts when the user starts forgetting a card.
    let learnedCount: Int
    let totalCount: Int

    /// Short label for UI. `nil` for empty decks (would be noise).
    var statusLabel: String? {
        if totalCount == 0 { return nil }
        if dueCount > 0 { return "\(dueCount) due" }
        if newCount == totalCount { return "New" }
        return "Up to date"
    }
}

/// Pure FSRS-5 update applied to a single card's schedule.
///
/// Why pure: keeping the algorithm free of Firestore / dates-from-now / IO lets us
/// unit-test it deterministically and tune weights independently of the IO layer.
/// The raw `CardReview` event log in `studySessions` remains the source of truth —
/// schedules are derivable from it.
///
/// FSRS-5 reference: github.com/open-spaced-repetition/fsrs4anki (default weights).
enum FSRSScheduler {

    // MARK: - Parameters

    /// Default FSRS-5 weights. Not currently tuned per user; values mirror the
    /// canonical reference implementation that ships with Anki.
    static let weights: [Double] = [
        0.40255, 1.18385, 3.173,   15.69105,
        7.1949,  0.5345,  1.4604,  0.0046,
        1.54575, 0.1192,  1.01925, 1.9395,
        0.11,    0.29605, 2.2698,  0.2315,
        2.9898,  0.51655, 0.6621
    ]

    /// Decay constant from the FSRS-5 forgetting curve `R = (1 + factor·t/S)^decay`.
    static let decay: Double = -0.5
    /// Computed once: `0.9^(1/decay) − 1 ≈ 0.23457`. Chosen so `R = 0.9` at `t = S`.
    static let factor: Double = pow(0.9, 1.0 / decay) - 1.0

    /// Baseline forgetting risk applied to never-reviewed cards. Tuned so a brand-new
    /// deck of N cards sits between a deck with overdue cards and a deck of recently
    /// reviewed cards in the Study tab's ordering.
    static let newCardForgettingRisk: Double = 0.3

    /// Stability (in days) at which a card is considered "learned" — i.e. the user
    /// has stacked enough correct grades that FSRS projects at least a week of
    /// retention. Looser than Anki's canonical 21-day "mature" threshold so a
    /// single `easy` grade or a couple of successful `good` reviews graduates a
    /// card, keeping the Learned count responsive on fresh decks without
    /// dropping all the way to "any review at all counts".
    static let learnedStabilityThresholdDays: Double = 7.0

    // MARK: - Forgetting curve / urgency

    /// Probability the card is still remembered now under FSRS-5: `(1 + factor·t/S)^decay`.
    static func retrievability(elapsedDays: Double, stability: Double) -> Double {
        let s = max(0.001, stability)
        return pow(1.0 + factor * max(0, elapsedDays) / s, decay)
    }

    /// Days until next review needed to land at `targetRetention` given `stability`.
    static func interval(stability: Double, targetRetention: Double) -> Int {
        let r = min(0.999, max(0.5, targetRetention))
        let raw = stability / factor * (pow(r, 1.0 / decay) - 1.0)
        return max(1, Int(raw.rounded()))
    }

    /// Per-card forgetting risk ∈ [0, 1]. Higher = more likely to be forgotten now.
    static func forgettingRisk(for schedule: CardSchedule?, at now: Date = Date()) -> Double {
        guard let schedule else { return newCardForgettingRisk }
        let elapsed = max(0, now.timeIntervalSince(schedule.lastReviewedAt)) / 86_400
        // Seed stability from the legacy SM-2 interval if FSRS state isn't populated
        // yet on this card — the first FSRS review will replace this with a real value.
        let stability = schedule.stability ?? max(1, Double(schedule.intervalDays))
        return 1.0 - retrievability(elapsedDays: elapsed, stability: stability)
    }

    static func urgency(
        for deck: DeckDocument,
        schedules: [String: CardSchedule],
        at now: Date = Date()
    ) -> DeckUrgency {
        var score = 0.0
        var dueCount = 0
        var newCount = 0
        var learnedCount = 0
        for item in deck.items {
            let schedule = schedules[item.id.uuidString]
            score += forgettingRisk(for: schedule, at: now)
            if let schedule {
                if schedule.nextReviewAt <= now { dueCount += 1 }
                // Stability is the FSRS memory-strength estimate in days. A
                // missing value means the card hasn't been graded under FSRS
                // yet (e.g. SM-2 legacy), so it can't yet count as learned.
                if let stability = schedule.stability,
                   stability >= learnedStabilityThresholdDays {
                    learnedCount += 1
                }
            } else {
                newCount += 1
            }
        }
        return DeckUrgency(
            score: score,
            dueCount: dueCount,
            newCount: newCount,
            learnedCount: learnedCount,
            totalCount: deck.items.count
        )
    }

    // MARK: - Schedule update

    static func apply(
        review: CardReview,
        existing: CardSchedule?,
        deckId: String,
        targetRetention: Double
    ) -> CardSchedule {
        let now = review.reviewedAt
        let grade = review.result
        let g = Double(grade.fsrsIndex)
        let w = weights

        let (newStability, newDifficulty, newLapses): (Double, Double, Int)

        if let existing, let s = existing.stability, let d = existing.difficulty {
            // Returning card with FSRS state — full update.
            let elapsed = max(0, now.timeIntervalSince(existing.lastReviewedAt)) / 86_400
            let r = retrievability(elapsedDays: elapsed, stability: s)

            // Difficulty: linearly nudge, then mean-revert toward the initial
            // difficulty for `easy` so cards trend back to baseline over time.
            let deltaD = -w[6] * (g - 3.0)
            let dPrime = d + deltaD * (10.0 - d) / 9.0
            let d0Easy = clampDifficulty(w[4] - exp(w[5] * 3.0) + 1.0) // G=4 ⇒ exponent (G-1)=3
            newDifficulty = clampDifficulty(w[7] * d0Easy + (1.0 - w[7]) * dPrime)

            if grade == .again {
                // Lapse: stability drops sharply, bounded so it never rises above
                // the prior value (a forget can't grow your memory).
                let sFail = w[11]
                    * pow(newDifficulty, -w[12])
                    * (pow(s + 1.0, w[13]) - 1.0)
                    * exp(w[14] * (1.0 - r))
                newStability = max(0.1, min(sFail, s))
                newLapses = existing.lapses + 1
            } else {
                let hardPenalty = grade == .hard ? w[15] : 1.0
                let easyBonus   = grade == .easy ? w[16] : 1.0
                let factorTerm = exp(w[8])
                    * (11.0 - newDifficulty)
                    * pow(s, -w[9])
                    * (exp(w[10] * (1.0 - r)) - 1.0)
                    * hardPenalty
                    * easyBonus
                newStability = max(0.1, s * (factorTerm + 1.0))
                newLapses = existing.lapses
            }
        } else {
            // First FSRS review of this card. Seed from legacy interval if present
            // (so SM-2 history isn't thrown away), otherwise use FSRS initial values.
            let seed = existing.flatMap { Double($0.intervalDays) }
            let s0 = seed.map { max(0.1, $0) } ?? max(0.1, w[grade.fsrsIndex - 1])
            newStability = s0
            newDifficulty = clampDifficulty(w[4] - exp(w[5] * (g - 1.0)) + 1.0)
            newLapses = (existing?.lapses ?? 0) + (grade == .again ? 1 : 0)
        }

        let intervalDays = interval(stability: newStability, targetRetention: targetRetention)
        let nextReviewAt = Calendar.current.date(byAdding: .day, value: intervalDays, to: now) ?? now

        return CardSchedule(
            id: existing?.id ?? review.cardId,
            cardId: review.cardId,
            deckId: deckId,
            word: review.word,
            language: review.language,
            stability: newStability,
            difficulty: newDifficulty,
            intervalDays: intervalDays,
            lapses: newLapses,
            lastReviewedAt: now,
            nextReviewAt: nextReviewAt,
            createdAt: existing?.createdAt ?? now,
            easeFactor: nil,
            repetitions: nil
        )
    }

    private static func clampDifficulty(_ d: Double) -> Double {
        max(1.0, min(10.0, d))
    }
}
