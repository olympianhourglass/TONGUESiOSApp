import SwiftUI
import Charts

// Statistics page reached from the Library tab's "View Statistics" button.
// Push-navigated inside the library NavigationStack so it slides in from
// the trailing edge. The Preferred Language card is wired to real practice
// data; the rest is still presentation-only mock data for now — wiring
// will come once the real metrics pipeline lands.
struct StatisticsView: View {
    // Per-language flashcard review totals, sourced from the same Firestore
    // `studySessions` aggregation that powers the Library tab's "Preferred
    // Language" metric. Passed in by the parent so we don't duplicate the
    // fetch; refreshes follow LibraryViewModel.loadDecks().
    let reviewsByLanguage: [String: Int]

    // FSRS-derived "learned so far": cards across every deck that the user
    // has graded at least once. Same urgency math the Library/Study tabs
    // already use.
    let itemsLearned: Int

    // Library inventory split by content type so the Words Learned card can
    // surface counts independently. Sentences are shown only when > 0 so
    // the card stays tight for users who only have words + phrases.
    let wordsInLibrary: Int
    let sentencesInLibrary: Int

    // Cards added to the library since the start of this week / month —
    // surfaced behind the Words Learned card's disclosure chevron.
    let cardsAddedThisWeek: Int
    let cardsAddedThisMonth: Int

    // Number of cards reviewed per calendar day, sourced from the same
    // `studySessions` aggregation that powers the streak. Drives the
    // contribution-style heatmap card.
    let practiceCountsByDay: [Date: Int]

    // Top-practiced deck summaries + a stable signature used to cache the
    // LLM-derived "favorite topic" label. Cache is keyed off the
    // signature so the same set of top decks reuses the previous result.
    let topPracticedDecks: [DeckTopicSummary]
    let topPracticedDecksSignature: String

    // Learning Experience card inputs — total XP mirrors the Library card,
    // and the preferred-method label is derived from the audio vs.
    // flashcard session split.
    let totalXP: Int
    let preferredLearningMethod: String

    // Per-day XP map (start-of-day → XP earned that day) used to draw
    // this week and last week as overlaid line series.
    let xpByDay: [Date: Int]

    // Session-length card inputs. Average + longest mirror the Library
    // tab metrics; longest-session-language is the language whose own
    // longest meta-session topped every other language. Best-learning
    // time is the FSRS-weighted time-of-day where the user is most
    // accurate and most consistent.
    let averageSessionSeconds: TimeInterval
    let longestSessionSeconds: TimeInterval
    let longestSessionLanguage: String
    let bestLearningTimeLabel: String

    // Day Statistics card input. Specific clock-time derived from the
    // same weighted-mean-success calc that drives `bestLearningTimeLabel`,
    // so the headline value always lands inside the broader bucket.
    let optimalLearningTimeLabel: String

    // Streak — passed in for the Overall Summary card's LLM context.
    let dailyStreak: Int

    @State private var favoriteTopic: String = ""
    @AppStorage("favoriteTopicSignature") private var cachedFavoriteTopicSignature: String = ""
    @AppStorage("favoriteTopicLabel") private var cachedFavoriteTopicLabel: String = ""

    @State private var overallSummary: String = ""
    @AppStorage("overallSummarySignature") private var cachedOverallSummarySignature: String = ""
    @AppStorage("overallSummaryText") private var cachedOverallSummaryText: String = ""

    @State private var sharePayload: SharePayload?

    @Environment(\.dismiss) private var dismiss
    @State private var isLanguagesExpanded = false
    @State private var isWordsLearnedExpanded = false
    // Day index (0…6) the user's finger is hovering over on the weekly
    // trend chart. Nil = no touch in progress, the chart renders flat
    // with no scrubber overlay.
    @State private var selectedDayIndex: Int? = nil

    // Languages sorted by review volume, paired with their share of the
    // user's total practice. Empty array when the user hasn't reviewed
    // anything yet.
    private var languageBreakdown: [(language: String, percent: Double)] {
        let total = reviewsByLanguage.values.reduce(0, +)
        guard total > 0 else { return [] }
        return reviewsByLanguage
            .sorted { $0.value > $1.value }
            .map { (language: $0.key, percent: Double($0.value) / Double(total)) }
    }

    private var topLanguageName: String {
        languageBreakdown.first?.language ?? "—"
    }

    // Three-tone bar: top language → white, second → mid gray, every
    // remaining language collapses into one dark-gray tail segment. Match
    // the design comp where the bar visually anchors the top two languages.
    private var preferredLanguageSegments: [(Double, Color)] {
        let entries = languageBreakdown
        switch entries.count {
        case 0:
            return [(1.0, Color(white: 0.20))]
        case 1:
            return [(1.0, .white)]
        case 2:
            return [
                (entries[0].percent, .white),
                (entries[1].percent, Color(white: 0.55))
            ]
        default:
            let restSum = entries.dropFirst(2).reduce(0.0) { $0 + $1.percent }
            return [
                (entries[0].percent, .white),
                (entries[1].percent, Color(white: 0.55)),
                (restSum, Color(white: 0.30))
            ]
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                overallSummaryCard
                preferredLanguageCard
                wordsLearnedCard
                sessionLengthCard
                weeklyTrendCard
                yearlyHeatmapCard
                dayStatisticsCard
                topicsCard
                learningExperienceCard
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .task {
            // Favorite topic first so the overall-summary prompt can
            // reference it; the overall summary then ties everything
            // together.
            await refreshFavoriteTopic()
            await refreshOverallSummary()
        }
        .sheet(item: $sharePayload) { payload in
            SharePreviewSheet(image: payload.image)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Force the Liquid Glass pills' glyphs to white. Without this, the
        // system picks up the app's default accent color, which read as the
        // tint blue/teal the user flagged as "funky" against our black bg.
        .tint(.white)
        .toolbar {
            // System renders these as Liquid Glass pills automatically when
            // they're plain Buttons inside .toolbar — no explicit .glass
            // style needed (per HIG, applying a button style on top of the
            // toolbar's own glass treatment double-stacks the material).
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.white)
                }
            }
            ToolbarItem(placement: .principal) {
                TonguesWordmark(size: 18)
                    .foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    if let image = renderShareImage() {
                        sharePayload = SharePayload(image: image)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: - Card chrome

    @ViewBuilder
    private func statCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: - Share card rendering

    // Builds the share card off the same fields the on-screen cards
    // already use, hands it to ImageRenderer at @3x for a sharp social
    // export, and returns the resulting UIImage. Called synchronously
    // from the toolbar tap — ImageRenderer is cheap enough at this size.
    @MainActor
    private func renderShareImage() -> UIImage? {
        let summary = overallSummary.isEmpty
            ? "A language learner getting started on TONGUES."
            : overallSummary
        let card = StatisticsShareCard(
            overallSummary: summary,
            preferredLanguage: languageBreakdown.first?.language ?? "—",
            streakDays: dailyStreak,
            totalXP: totalXP
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage
    }

    // MARK: - Overall summary (top card)

    private var overallSummaryCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Overall Summary")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.8)

                Text(overallSummary.isEmpty
                     ? "Start practicing to see your learner profile."
                     : overallSummary)
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // Stable cache key for the LLM call. Includes every input the prompt
    // actually depends on so a meaningful profile shift triggers a refresh,
    // but excludes highly-volatile values (like raw XP) that would
    // invalidate the cache on every load.
    private var overallSummarySignature: String {
        let topLang = languageBreakdown.first?.language ?? ""
        let practicedList = languageBreakdown.prefix(3).map(\.language).joined(separator: ",")
        return [
            topLang,
            practicedList,
            preferredLearningMethod,
            bestLearningTimeLabel,
            favoriteTopic,
            // Coarse streak bucket so e.g. crossing 7/30/100 refreshes the
            // text but day-to-day increments don't.
            "streak:\(streakBucket(dailyStreak))"
        ].joined(separator: "|")
    }

    private func streakBucket(_ streak: Int) -> Int {
        switch streak {
        case 0:          return 0
        case 1..<7:      return 1
        case 7..<30:     return 2
        case 30..<100:   return 3
        default:         return 4
        }
    }

    // Mirrors the favorite-topic refresh: returns immediately on cache
    // hit, shows the stale label while a re-fetch is in flight on
    // signature change, and stays silent (no card content) when there's
    // nothing meaningful to summarize yet.
    private func refreshOverallSummary() async {
        let sig = overallSummarySignature
        let sigBody = sig.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "streak:0", with: "")
        guard !sigBody.isEmpty else {
            overallSummary = ""
            return
        }
        if cachedOverallSummarySignature == sig, !cachedOverallSummaryText.isEmpty {
            overallSummary = cachedOverallSummaryText
            return
        }
        if !cachedOverallSummaryText.isEmpty {
            overallSummary = cachedOverallSummaryText
        }
        do {
            let topLangs = languageBreakdown.prefix(3).map(\.language)
            let text = try await DeckGenerator.summarizeOverallLearner(
                topLanguage: languageBreakdown.first?.language,
                preferredMethod: preferredLearningMethod,
                bestLearningTime: bestLearningTimeLabel,
                favoriteTopic: favoriteTopic,
                streakDays: dailyStreak,
                totalXP: totalXP,
                topLanguagesByPractice: topLangs
            )
            guard !text.isEmpty else { return }
            overallSummary = text
            cachedOverallSummarySignature = sig
            cachedOverallSummaryText = text
        } catch {
            print("Overall summary failed: \(error)")
        }
    }

    // MARK: - Card 1: Preferred language breakdown

    @ViewBuilder
    private var preferredLanguageCard: some View {
        statCard {
            if languageBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    emphasizedLine(
                        prefix: "Practice some flashcards to surface your ",
                        emphasis: "preferred language",
                        suffix: "."
                    )
                    Text("We rank languages by how many reviews you've completed across all your decks.")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    emphasizedLine(
                        prefix: "Your preferred language is ",
                        emphasis: topLanguageName
                    )

                    stackedBar(segments: preferredLanguageSegments)

                    VStack(spacing: 8) {
                        let visible = isLanguagesExpanded
                            ? languageBreakdown
                            : Array(languageBreakdown.prefix(3))
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, entry in
                            languageRow(entry.language, percentLabel(entry.percent))
                        }
                    }

                    // Chevron only appears when there's actually more to
                    // expand. Tapping toggles between top-3 and full list.
                    if languageBreakdown.count > 3 {
                        Button {
                            Haptics.light()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isLanguagesExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: isLanguagesExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func percentLabel(_ value: Double) -> String {
        // Round to the nearest whole percent. Sub-1% languages still show as
        // "1%" so the row reads as something rather than "0%".
        let raw = value * 100
        let rounded = Int(raw.rounded())
        if rounded == 0 && raw > 0 { return "1%" }
        return "\(rounded)%"
    }

    // MARK: - Card 2: Words / library counts

    private var wordsLearnedCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 6) {
                emphasizedLine(
                    prefix: "You've learned ",
                    emphasis: pluralized(itemsLearned, unit: learnedUnit),
                    suffix: "."
                )
                emphasizedLine(
                    prefix: "Your library contains ",
                    emphasis: pluralized(wordsInLibrary, unit: "word"),
                    suffix: "."
                )
                // Sentences only show if the user actually has any, so the
                // card doesn't grow a phantom "0 sentences" line.
                if sentencesInLibrary > 0 {
                    emphasizedLine(
                        prefix: "Your library contains ",
                        emphasis: pluralized(sentencesInLibrary, unit: "sentence"),
                        suffix: "."
                    )
                }

                // Reveal "added this week / month" behind the chevron so the
                // resting card stays compact. Both lines stay visible when
                // expanded — including 0 counts — so the user always knows
                // whether the metric was reported or just empty.
                if isWordsLearnedExpanded {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.vertical, 8)
                    emphasizedLine(
                        prefix: "You've added ",
                        emphasis: pluralized(cardsAddedThisWeek, unit: "card"),
                        suffix: " this week."
                    )
                    emphasizedLine(
                        prefix: "You've added ",
                        emphasis: pluralized(cardsAddedThisMonth, unit: "card"),
                        suffix: " this month."
                    )
                }

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isWordsLearnedExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: isWordsLearnedExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Pick the unit for the "learned" headline. If the user only has Words
    // decks, "words" reads naturally; once any phrases/sentences exist
    // we switch to the type-agnostic "card" to stay accurate.
    private var learnedUnit: String {
        sentencesInLibrary == 0 ? "word" : "card"
    }

    private func pluralized(_ count: Int, unit: String) -> String {
        let label = count == 1 ? unit : "\(unit)s"
        return "\(StatisticsView.integerFormatter.string(from: NSNumber(value: count)) ?? "\(count)") \(label)"
    }

    // Shared so we're not allocating a NumberFormatter per render.
    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    // MARK: - Card 3: Session length / best time

    private var sessionLengthCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 14) {
                if averageSessionSeconds > 0 {
                    emphasizedLine(
                        prefix: "Your average session length is ",
                        emphasis: formattedAverageSession,
                        suffix: "."
                    )
                } else {
                    emphasizedLine(
                        prefix: "Start a session to surface your ",
                        emphasis: "average session length",
                        suffix: "."
                    )
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Longest Session")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Longest Session Language")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(formattedLongestSession)
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white)
                        Text(longestSessionLanguage.isEmpty ? "—" : longestSessionLanguage)
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white)
                    }
                }

                if bestLearningTimeLabel.isEmpty {
                    emphasizedLine(
                        prefix: "We'll surface your ",
                        emphasis: "best learning time",
                        suffix: " after a few sessions."
                    )
                } else {
                    emphasizedLine(
                        prefix: "Your best learning time is ",
                        emphasis: bestLearningTimeLabel,
                        suffix: "."
                    )
                }
            }
        }
    }

    // Round average to nearest minute for the headline. Sub-minute
    // sessions read more naturally as seconds — same logic the Library
    // tab's longest-session label uses.
    private var formattedAverageSession: String {
        let totalSeconds = Int(averageSessionSeconds.rounded())
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    // Mirrors the Library tab's "Longest Session" formatting so the two
    // surfaces agree: "X min" under an hour, "H:MM Hours" at or above.
    private var formattedLongestSession: String {
        guard longestSessionSeconds > 0 else { return "—" }
        let totalMinutes = max(1, Int(longestSessionSeconds / 60))
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours == 0 { return "\(mins) min" }
        return String(format: "%d:%02d Hours", hours, mins)
    }

    // MARK: - Card 4: Weekly trend chart

    private var weeklyTrendCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 16) {
                weeklyTrendCommentary

                Chart {
                    // Last week sits underneath as a shadow series, drawn
                    // first so this week's line is layered on top. X is
                    // the day-of-week index (0…6) rather than the short
                    // letter — using letters collapses Sun/Sat onto "S"
                    // and Tue/Thu onto "T" because the chart treats
                    // duplicate categorical values as the same x.
                    ForEach(lastWeekChartData) { entry in
                        LineMark(
                            x: .value("Day", entry.id),
                            y: .value("XP", entry.xp),
                            series: .value("Week", "Last week")
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.white.opacity(0.30))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        PointMark(
                            x: .value("Day", entry.id),
                            y: .value("XP", entry.xp)
                        )
                        .foregroundStyle(Color.white.opacity(0.30))
                        .symbolSize(45)
                    }
                    ForEach(thisWeekChartData) { entry in
                        LineMark(
                            x: .value("Day", entry.id),
                            y: .value("XP", entry.xp),
                            series: .value("Week", "This week")
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(.white)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                        PointMark(
                            x: .value("Day", entry.id),
                            y: .value("XP", entry.xp)
                        )
                        .foregroundStyle(.white)
                        .symbolSize(70)
                    }

                    // Scrubber: vertical line + point markers wherever
                    // the user's finger lands on the chart. Drawn last
                    // so it sits above both series.
                    if let idx = selectedDayIndex {
                        RuleMark(x: .value("Day", idx))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(
                                position: .top,
                                alignment: .center,
                                spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                scrubberCallout(forDayIndex: idx)
                            }
                    }
                }
                // Pad the domain by half a day on each side so the Monday(0)
                // and Sunday(6) points sit inset from the plot edges — this
                // gives their centered weekday labels room to align under the
                // dots and keeps the last label (Sat/Sun) from clipping.
                .chartXScale(domain: -0.5...6.5)
                .chartXAxis {
                    AxisMarks(values: Array(0...6)) { value in
                        // anchor: .top pins the label's top-CENTER to its
                        // value, so each weekday letter sits horizontally
                        // centered under its dot. Without it the label
                        // attaches by its leading edge and hangs to the
                        // right, making every dot look skewed left of its day.
                        AxisValueLabel(centered: false, anchor: .top) {
                            if let idx = value.as(Int.self), idx >= 0, idx < weekdayLabels.count {
                                Text(weekdayLabels[idx])
                                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel {
                            if let amount = value.as(Int.self) {
                                Text("\(amount) XP")
                                    .font(.custom("NeueHaasDisplay-Light", size: 10))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...max(8, weeklyChartYMax))
                .frame(height: 180)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let plotOrigin = geo[plotFrame].origin
                                        let xInPlot = drag.location.x - plotOrigin.x
                                        if let dayDouble: Double = proxy.value(atX: xInPlot) {
                                            let idx = min(6, max(0, Int(dayDouble.rounded())))
                                            if selectedDayIndex != idx {
                                                selectedDayIndex = idx
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        selectedDayIndex = nil
                                    }
                            )
                    }
                }

                HStack(spacing: 18) {
                    legendDot(color: .white, label: "This week")
                    legendDot(color: Color.white.opacity(0.30), label: "Last week", dashed: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // Floating readout that follows the scrubber. Surfaces the
    // full day label and the XP for both series at that day, so
    // riding the chart actually communicates something more
    // specific than the visual line crossing.
    @ViewBuilder
    private func scrubberCallout(forDayIndex idx: Int) -> some View {
        let thisXP = Int(thisWeekChartData.first { $0.id == idx }?.xp ?? 0)
        let lastXP = Int(lastWeekChartData.first { $0.id == idx }?.xp ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            Text(fullWeekdayLabel(forIndex: idx))
                .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                .foregroundStyle(.white)
            Text("This week: \(thisXP) XP")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.white.opacity(0.85))
            if lastXP > 0 {
                Text("Last week: \(lastXP) XP")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // Long-form weekday label resolved from the same first-weekday
    // offset the chart x-axis uses, so the callout day always lines
    // up with the column the scrubber is parked over.
    private func fullWeekdayLabel(forIndex idx: Int) -> String {
        let calendar = Calendar.current
        let symbols = calendar.standaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        let rotated = Array(symbols[offset...]) + Array(symbols[..<offset])
        guard idx >= 0, idx < rotated.count else { return "" }
        return rotated[idx]
    }

    private func legendDot(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dashed {
                // Dashed mini-stroke mirrors the last-week line so the
                // legend matches the chart visually at a glance.
                Capsule()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    .frame(width: 18, height: 4)
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 18, height: 2)
            }
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Weekly trend data

    private struct WeeklyXPEntry: Identifiable {
        let id: Int
        let label: String
        let xp: Double
    }

    private var thisWeekRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start, end)
    }

    private var lastWeekRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let thisStart = thisWeekRange.start
        let start = calendar.date(byAdding: .day, value: -7, to: thisStart) ?? thisStart
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start, end)
    }

    private var chartXDomain: [String] { weekdayLabels }

    // Day-of-week labels rotated to the user's calendar first weekday so
    // the X-axis order matches the visual week (Sun-first in US,
    // Mon-first in most of Europe).
    private var weekdayLabels: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private var thisWeekChartData: [WeeklyXPEntry] {
        buildEntries(weekStart: thisWeekRange.start, clampFutureDays: true)
    }

    private var lastWeekChartData: [WeeklyXPEntry] {
        buildEntries(weekStart: lastWeekRange.start, clampFutureDays: false)
    }

    // For "this week", days past today haven't happened yet — render
    // them as 0 so the line doesn't project into the future. Last week
    // is always full.
    private func buildEntries(weekStart: Date, clampFutureDays: Bool) -> [WeeklyXPEntry] {
        let calendar = Calendar.current
        let labels = weekdayLabels
        let today = calendar.startOfDay(for: Date())
        var entries: [WeeklyXPEntry] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let isFuture = clampFutureDays && day > today
            let xp = isFuture ? 0 : (xpByDay[day] ?? 0)
            entries.append(WeeklyXPEntry(id: offset, label: labels[offset], xp: Double(xp)))
        }
        return entries
    }

    private var weeklyChartYMax: Double {
        let pool = thisWeekChartData.map(\.xp) + lastWeekChartData.map(\.xp)
        let peak = pool.max() ?? 0
        return peak * 1.15
    }

    @ViewBuilder
    private var weeklyTrendCommentary: some View {
        let thisTotal = thisWeekChartData.reduce(0) { $0 + Int($1.xp) }
        let lastTotal = lastWeekChartData.reduce(0) { $0 + Int($1.xp) }

        if thisTotal == 0 && lastTotal == 0 {
            Text("Practice this week to start building your XP trend.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        } else if lastTotal == 0 {
            emphasizedLine(
                prefix: "You've earned ",
                emphasis: "\(thisTotal) XP",
                suffix: " this week — no baseline yet from last week."
            )
        } else if thisTotal == lastTotal {
            emphasizedLine(
                prefix: "You're ",
                emphasis: "matching last week's pace",
                suffix: "."
            )
        } else if thisTotal > lastTotal {
            let percent = Int(((Double(thisTotal) - Double(lastTotal)) / Double(lastTotal) * 100).rounded())
            emphasizedLine(
                prefix: "You are ",
                emphasis: "outperforming last week by \(percent)%"
            )
        } else {
            let percent = Int(((Double(lastTotal) - Double(thisTotal)) / Double(lastTotal) * 100).rounded())
            emphasizedLine(
                prefix: "You're ",
                emphasis: "behind last week by \(percent)%"
            )
        }
    }

    // MARK: - Card 5: Practice heatmap

    private var yearlyHeatmapCard: some View {
        statCard {
            PracticeHeatmap(countsByDay: practiceCountsByDay)
        }
    }

    // MARK: - Card 6: Day Statistics

    private var dayStatisticsCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Day Statistics")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optimal Learning Time:")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(optimalLearningTimeLabel.isEmpty ? "—" : optimalLearningTimeLabel)
                        .font(.custom("NeueHaasDisplay-Light", size: 44))
                        .foregroundStyle(.white)
                }
                Text("Weighted average of the hour-of-day your reviews land correctly")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Card 7: Topics

    private var topicsCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Topics:")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Favorite Topic:")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(favoriteTopic.isEmpty ? "—" : favoriteTopic)
                        .font(.custom("NeueHaasDisplay-Light", size: 44))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                Text("Summarized from the decks you've practiced the most")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // Returns immediately when the cached signature still matches the top
    // deck set; otherwise kicks off a Haiku call and refreshes the cache.
    // Empty-state (no practice yet) clears the label so the card reads
    // "—" honestly rather than showing a stale topic.
    private func refreshFavoriteTopic() async {
        guard !topPracticedDecks.isEmpty else {
            favoriteTopic = ""
            return
        }
        if cachedFavoriteTopicSignature == topPracticedDecksSignature,
           !cachedFavoriteTopicLabel.isEmpty {
            favoriteTopic = cachedFavoriteTopicLabel
            return
        }
        // Show the cached label (if any) while the refresh is in flight
        // so the card doesn't flash to "—" on signature change.
        if !cachedFavoriteTopicLabel.isEmpty {
            favoriteTopic = cachedFavoriteTopicLabel
        }
        do {
            let label = try await DeckGenerator.summarizeFavoriteTopic(decks: topPracticedDecks)
            guard !label.isEmpty else { return }
            favoriteTopic = label
            cachedFavoriteTopicSignature = topPracticedDecksSignature
            cachedFavoriteTopicLabel = label
        } catch {
            print("Favorite topic summary failed: \(error)")
        }
    }

    // MARK: - Card 8: Learning Experience

    private var learningExperienceCard: some View {
        statCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Learning Experience:")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Learning Method:")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(preferredLearningMethod)
                        .font(.custom("NeueHaasDisplay-Light", size: 36))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Total Experience:")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(formattedTotalXP)
                        .font(.custom("NeueHaasDisplay-Light", size: 36))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var formattedTotalXP: String {
        let number = Self.integerFormatter.string(from: NSNumber(value: totalXP)) ?? "\(totalXP)"
        return "\(number) XP"
    }

    // MARK: - Building blocks

    // Composed Text run so the prefix/suffix and the emphasized middle
    // share one wrapped block — keeps line breaks natural even when the
    // emphasis is a long phrase.
    private func emphasizedLine(prefix: String, emphasis: String, suffix: String = "") -> some View {
        (Text(prefix)
            .font(.custom("NeueHaasDisplay-Light", size: 14))
            .foregroundColor(.white)
         + Text(emphasis)
            .font(.custom("NeueHaasDisplay-Bold", size: 14))
            .foregroundColor(.white)
         + Text(suffix)
            .font(.custom("NeueHaasDisplay-Light", size: 14))
            .foregroundColor(.white))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageRow(_ name: String, _ percent: String) -> some View {
        HStack {
            Text(name)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(percent)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func stackedBar(segments: [(Double, Color)]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: proxy.size.width * seg.0)
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    private var disclosureChevron: some View {
        HStack {
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
    }

}

// MARK: - Practice heatmap

// Contribution-graph style tiling with three zoom levels (year / month /
// week). Cells are colored by how many cards the user reviewed that day,
// normalized against the brightest day in the visible window so the
// intensity scale stays meaningful regardless of period length.
private struct PracticeHeatmap: View {
    let countsByDay: [Date: Int]

    enum Mode: String, CaseIterable, Identifiable {
        case yearly = "Yearly"
        case monthly = "Monthly"
        case weekly  = "Weekly"
        var id: String { rawValue }

        var calendarComponent: Calendar.Component {
            switch self {
            case .yearly:  return .year
            case .monthly: return .month
            case .weekly:  return .weekOfYear
            }
        }
    }

    @State private var mode: Mode = .yearly
    @State private var anchor: Date = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controlsRow
            grid
        }
    }

    // MARK: Controls row (mode menu | period label | nav arrows)

    private var controlsRow: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Mode.allCases) { m in
                    Button(m.rawValue) {
                        mode = m
                        anchor = Date()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(mode.rawValue)
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            Text(periodLabel)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 18) {
                Button {
                    Haptics.light()
                    shift(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button {
                    Haptics.light()
                    shift(by: +1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func shift(by delta: Int) {
        if let new = calendar.date(byAdding: mode.calendarComponent, value: delta, to: anchor) {
            withAnimation(.easeInOut(duration: 0.15)) {
                anchor = new
            }
        }
    }

    // MARK: Period label

    private var periodLabel: String {
        let f = DateFormatter()
        f.locale = .current
        switch mode {
        case .yearly:
            f.dateFormat = "yyyy"
            return f.string(from: anchor)
        case .monthly:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: anchor)
        case .weekly:
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start,
                  let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
                return ""
            }
            f.dateFormat = "MMM d"
            return "\(f.string(from: weekStart)) – \(f.string(from: weekEnd))"
        }
    }

    // MARK: Grid (mode-specific)

    @ViewBuilder
    private var grid: some View {
        switch mode {
        case .yearly:  yearlyGrid
        case .monthly: monthlyGrid
        case .weekly:  weeklyGrid
        }
    }

    // GitHub-style. 7 rows (Sun → Sat in current calendar) × ~53 columns.
    // Cells outside the selected year render as the empty-cell color so
    // the grid stays rectangular without lying about activity.
    private var yearlyGrid: some View {
        let year = calendar.component(.year, from: anchor)
        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? anchor
        let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? anchor
        let columnStart = startOfWeek(containing: yearStart)
        let totalDays = (calendar.dateComponents([.day], from: columnStart, to: yearEnd).day ?? 0) + 1
        let columns = max(1, (totalDays + 6) / 7)
        let maxCount = maxCount(in: yearStart...yearEnd)

        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let cellSize = max(2, (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            VStack(spacing: spacing) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { col in
                            cell(
                                at: calendar.date(byAdding: .day, value: col * 7 + row, to: columnStart) ?? columnStart,
                                bounds: yearStart...yearEnd,
                                maxCount: maxCount,
                                size: cellSize
                            )
                        }
                    }
                }
            }
        }
        .aspectRatio(CGFloat(columns) / 7, contentMode: .fit)
    }

    // 7 columns (weekday labels above), N rows (one per week of the month).
    // First row is offset so the first-of-month lands on the correct
    // weekday column.
    private var monthlyGrid: some View {
        let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start ?? anchor
        let monthRange = calendar.range(of: .day, in: .month, for: anchor) ?? 1..<2
        let daysInMonth = monthRange.count
        let leadingOffset = (calendar.component(.weekday, from: monthStart) - 1)  // 0..6
        let totalCells = leadingOffset + daysInMonth
        let rows = (totalCells + 6) / 7
        let monthEnd = calendar.date(byAdding: .day, value: daysInMonth - 1, to: monthStart) ?? monthStart
        let maxCount = maxCount(in: monthStart...monthEnd)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(weekdayHeaders, id: \.self) { label in
                    Text(label)
                        .font(.custom("NeueHaasDisplay-Light", size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { proxy in
                let spacing: CGFloat = 4
                let cellSize = max(2, (proxy.size.width - spacing * 6) / 7)
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { col in
                                let dayIndex = row * 7 + col - leadingOffset
                                if dayIndex < 0 || dayIndex >= daysInMonth {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                } else {
                                    cell(
                                        at: calendar.date(byAdding: .day, value: dayIndex, to: monthStart) ?? monthStart,
                                        bounds: monthStart...monthEnd,
                                        maxCount: maxCount,
                                        size: cellSize
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .aspectRatio(7 / CGFloat(rows), contentMode: .fit)
        }
    }

    // Single row of 7 cells with weekday labels under each — the larger
    // cell size makes the day-by-day rhythm more readable than the
    // micro-grid of the yearly view.
    private var weeklyGrid: some View {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let maxCount = maxCount(in: weekStart...weekEnd)

        return VStack(spacing: 8) {
            GeometryReader { proxy in
                let spacing: CGFloat = 6
                let cellSize = max(2, (proxy.size.width - spacing * 6) / 7)
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { idx in
                        cell(
                            at: calendar.date(byAdding: .day, value: idx, to: weekStart) ?? weekStart,
                            bounds: weekStart...weekEnd,
                            maxCount: maxCount,
                            size: cellSize
                        )
                    }
                }
            }
            .aspectRatio(7, contentMode: .fit)

            HStack(spacing: 0) {
                ForEach(weekdayHeaders, id: \.self) { label in
                    Text(label)
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Cells & color buckets

    private func cell(
        at date: Date,
        bounds: ClosedRange<Date>,
        maxCount: Int,
        size: CGFloat
    ) -> some View {
        let day = calendar.startOfDay(for: date)
        let inRange = bounds.contains(date)
        let count = inRange ? (countsByDay[day] ?? 0) : 0
        return Rectangle()
            .fill(cellColor(count: count, maxCount: maxCount, inRange: inRange))
            .frame(width: size, height: size)
    }

    // White-on-black ramp: faint slab for empty days inside the window,
    // fully transparent for days outside the window. We bucket so the
    // visible jumps in intensity feel deliberate instead of muddy gradient.
    private func cellColor(count: Int, maxCount: Int, inRange: Bool) -> Color {
        guard inRange else { return Color.clear }
        if count == 0 || maxCount == 0 { return Color.white.opacity(0.06) }
        let normalized = Double(count) / Double(maxCount)
        switch normalized {
        case ..<0.20: return Color.white.opacity(0.20)
        case ..<0.45: return Color.white.opacity(0.40)
        case ..<0.70: return Color.white.opacity(0.60)
        case ..<0.90: return Color.white.opacity(0.80)
        default:      return Color.white
        }
    }

    private func maxCount(in range: ClosedRange<Date>) -> Int {
        countsByDay
            .filter { range.contains($0.key) }
            .values
            .max() ?? 0
    }

    // MARK: Helpers

    private func startOfWeek(containing date: Date) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let firstWeekday = calendar.firstWeekday
        let offset = (weekday - firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: date) ?? date
    }

    private var weekdayHeaders: [String] {
        // Rotate the short symbols so they start at the user's calendar's
        // first weekday (Sun in US, Mon in much of Europe).
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }
}

// MARK: - Share card

// `sheet(item:)` requires Identifiable. UIImage isn't, so this thin
// wrapper carries the rendered card as the sheet's source-of-truth.
private struct SharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// Square 1080×1080 card rendered by ImageRenderer. Mirrors the on-screen
// dark theme (black bg, white text, PlayfairDisplay title, Neue Haas
// Display body) so it reads as part of the TONGUES design family when
// reposted to social.
struct StatisticsShareCard: View {
    let overallSummary: String
    let preferredLanguage: String
    let streakDays: Int
    let totalXP: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title — Playfair, generously sized so it reads as the
            // brand identifier in a feed thumbnail.
            HStack {
                TonguesWordmark(size: 84)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.top, 12)

            // Overall Summary block — boxed in the same `Color(white: 0.08)`
            // chrome the on-screen cards use, so the share card feels
            // like it was lifted straight from the Statistics tab.
            VStack(alignment: .leading, spacing: 18) {
                Text("OVERALL SUMMARY")
                    .font(.custom("NeueHaasDisplay-Light", size: 18))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.6))
                Text(overallSummary)
                    .font(.custom("NeueHaasDisplay-Light", size: 30))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.top, 48)

            Spacer(minLength: 0)

            // Three-row stat block with right-aligned bold values, same
            // style as the longest-session rows in the on-screen card.
            VStack(spacing: 22) {
                statRow(label: "Preferred Language", value: preferredLanguage)
                Divider().background(Color.white.opacity(0.12))
                statRow(label: "Streak", value: "\(streakDays) \(streakDays == 1 ? "day" : "days")")
                Divider().background(Color.white.opacity(0.12))
                statRow(label: "Experience", value: formattedXP)
            }

            // Footer wordmark in small caps so the card has the same
            // call-and-response top/bottom rhythm as a magazine cover.
            HStack {
                Spacer()
                Text("tongues.app")
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.top, 36)
        }
        .padding(56)
        .frame(width: 1080, height: 1080, alignment: .topLeading)
        .background(Color.black)
    }

    private var formattedXP: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let s = f.string(from: NSNumber(value: totalXP)) ?? "\(totalXP)"
        return "\(s) XP"
    }

    private func statRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 22))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .font(.custom("NeueHaasDisplay-Bold", size: 30))
                .foregroundStyle(.white)
        }
    }
}

// Preview-then-share sheet. Lives between the toolbar tap and the
// system share UI so the user can see exactly what's being sent before
// it goes out. The card image itself is pre-rendered (UIImage) so this
// view never re-runs ImageRenderer; the on-screen preview and the
// shared file are the same bytes.
private struct SharePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Preview your card. Tap Share when you're ready.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)

                        // The rendered share-card image, displayed
                        // 1:1 aspect with a soft border + shadow so it
                        // sits like a sample card on a sheet of paper.
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 6)
                            .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                // Pinned Share CTA. Capsule fill + 17pt semibold mirrors
                // the primary action style used by ProfileView's Log Out
                // and FeedbackSheet's send button, so the look matches
                // the rest of the app's modal CTAs.
                ShareLink(
                    item: Image(uiImage: image),
                    preview: SharePreview(
                        "Your TONGUES stats",
                        image: Image(uiImage: image)
                    )
                ) {
                    Text("Share")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Haptics.light() })
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .padding(.top, 12)
                .background(Color.white)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
