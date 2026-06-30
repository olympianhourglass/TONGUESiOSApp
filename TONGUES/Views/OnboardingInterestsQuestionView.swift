import SwiftUI

// Onboarding Q8: "What are you most interested in?"
// Two hardcoded chip sections (profession + hobbies), each with 10
// parent chips. Tapping a parent chip toggles it AND reveals a row of
// 10 pre-baked sub-chips beneath. A custom text field at the top lets
// the user add their own interest; manual entries trigger a Haiku call
// to generate 10 sub-chips specific to that interest.
struct OnboardingInterestsQuestionView: View {
    let questionNumber: Int
    let totalQuestions: Int
    let state: OnboardingState
    let onNext: () -> Void
    var showsProgress: Bool = true

    @State private var customDraft: String = ""
    @State private var selected: Set<String> = []
    @State private var customParents: [String] = []
    @State private var customSubChips: [String: [String]] = [:]
    @State private var loadingCustom: Set<String> = []

    @FocusState private var customFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    customEntryField

                    if !customParents.isEmpty {
                        section(title: "YOUR INTERESTS", chips: customParents, allowSubchips: true)
                    }

                    section(title: "PROFESSION", chips: Self.professions.map(\.label), allowSubchips: true, lookup: Self.professionLookup)
                    section(title: "HOBBIES", chips: Self.hobbies.map(\.label), allowSubchips: true, lookup: Self.hobbyLookup)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }

            nextButton
        }
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .onAppear {
            // Seed from previously-recorded answers so back-navigating
            // and forward again restores the user's selections.
            selected = Set(state.interests)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsProgress {
                Text("Question \(questionNumber) of \(totalQuestions)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            Text("What are you most interested in?")
                .font(.custom("PlayfairDisplay-Regular", size: 28))
                .tracking(-2.24)
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Custom interest field

    private var customEntryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Add your own interest…", text: $customDraft)
                .font(.system(size: 15))
                .submitLabel(.done)
                .focused($customFieldFocused)
                .onSubmit { submitCustomInterest() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(
            Capsule().stroke(Color(white: 0.85), lineWidth: 1)
        )
    }

    private func submitCustomInterest() {
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedupe — case-insensitive match against any existing chip we
        // already know about, so we don't end up with "Photography" and
        // "photography" as two separate parents.
        let allKnown = Self.professions.map(\.label)
            + Self.hobbies.map(\.label)
            + customParents
        if allKnown.contains(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            customDraft = ""
            return
        }

        customParents.append(trimmed)
        selected.insert(trimmed)
        loadingCustom.insert(trimmed)
        customDraft = ""
        customFieldFocused = false

        // Kick off a Haiku call to flesh out the new interest with
        // sub-chips. Failure is silent — the parent chip stays selected
        // either way.
        Task {
            let chips = (try? await DeckGenerator.suggestRelatedInterests(forInterest: trimmed)) ?? []
            await MainActor.run {
                customSubChips[trimmed] = chips
                loadingCustom.remove(trimmed)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(
        title: String,
        chips: [String],
        allowSubchips: Bool,
        lookup: ((String) -> [String]?)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            FlowLayout(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    chipButton(chip, isParent: true)
                }
            }

            if allowSubchips {
                ForEach(chips.filter { selected.contains($0) }, id: \.self) { parent in
                    let subs = lookup?(parent) ?? customSubChips[parent] ?? []
                    if loadingCustom.contains(parent) {
                        // Inline progress while we wait on Haiku to
                        // return sub-chips for a custom entry.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding related interests for \(parent)…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    } else if !subs.isEmpty {
                        subChipRow(parent: parent, subs: subs)
                    }
                }
            }
        }
    }

    private func subChipRow(parent: String, subs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(parent.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .tracking(0.6)
                .padding(.leading, 4)
            FlowLayout(spacing: 6) {
                ForEach(subs, id: \.self) { sub in
                    chipButton(sub, isParent: false)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.96))
                .padding(.leading, -4)
                .padding(.trailing, -4)
                .padding(.vertical, -4)
        )
    }

    // MARK: - Chip

    private func chipButton(_ chip: String, isParent: Bool) -> some View {
        let isSelected = selected.contains(chip)
        return Button {
            Haptics.light()
            if isSelected {
                selected.remove(chip)
            } else {
                selected.insert(chip)
            }
        } label: {
            Text(chip)
                .font(.system(size: isParent ? 14 : 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.black)
                .padding(.horizontal, isParent ? 14 : 12)
                .padding(.vertical, isParent ? 8 : 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.black : Color.white)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.black : Color(white: 0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Next button

    private var nextButton: some View {
        Button {
            Haptics.medium()
            state.interests = Array(selected)
            onNext()
        } label: {
            Text("Next")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .padding(.top, 8)
    }

    // MARK: - Hardcoded data

    fileprivate struct InterestCategory {
        let label: String
        let subChips: [String]
    }

    fileprivate static let professions: [InterestCategory] = [
        .init(label: "Diplomacy", subChips: ["Treaties", "Protocol", "Embassies", "Visas", "Statecraft", "Negotiation", "Bilateral talks", "Foreign service", "Geopolitics", "Multilateralism"]),
        .init(label: "Translation", subChips: ["Interpretation", "Subtitling", "Dubbing", "Literary translation", "Legal translation", "Medical translation", "Conference work", "Localization", "CAT tools", "Style guides"]),
        .init(label: "International Journalism", subChips: ["Foreign correspondent", "War reporting", "Bureaus", "Documentary", "Broadcast", "Op-ed", "Investigative", "Wire services", "Press conferences", "Fixers"]),
        .init(label: "International Business", subChips: ["Trade", "M&A", "Strategy", "Logistics", "Procurement", "Consulting", "Markets", "Partnerships", "Negotiation", "Cross-border finance"]),
        .init(label: "Hospitality", subChips: ["Hotels", "Concierge", "Tour guiding", "Cruises", "Airlines", "Sommelier", "Front office", "Resorts", "Events", "Reservations"]),
        .init(label: "Aid & NGO Work", subChips: ["Refugee aid", "Public health", "Field work", "Humanitarian", "Disaster response", "Grants", "Community organizing", "Development", "Policy", "Resettlement"]),
        .init(label: "Linguistics & Academia", subChips: ["Phonetics", "Syntax", "Sociolinguistics", "Historical linguistics", "Comparative grammar", "Field research", "TESOL", "Lexicography", "Translation theory", "Anthropology"]),
        .init(label: "Tech & Localization", subChips: ["UX writing", "i18n", "QA testing", "Pseudo-localization", "RTL design", "Glossaries", "Crowdin", "Phrase", "Hreflang", "Date/number formatting"]),
        .init(label: "International Law", subChips: ["Immigration", "Treaties", "Arbitration", "Compliance", "Corporate", "Human rights", "Maritime law", "Intellectual property", "Cross-border M&A", "Mediation"]),
        .init(label: "Global Health & Medicine", subChips: ["Doctors Without Borders", "Epidemiology", "Tropical medicine", "Medical interpreting", "Refugee clinics", "Vaccines", "WHO", "Field medicine", "Public health policy", "Bedside translation"])
    ]

    fileprivate static let hobbies: [InterestCategory] = [
        .init(label: "Specialty Coffee", subChips: ["Espresso", "Pour-over", "Roasters", "Single-origin", "V60", "Chemex", "Cupping", "Latte art", "Café culture", "Beans"]),
        .init(label: "Foreign Cinema", subChips: ["French New Wave", "Anime", "K-drama", "Wong Kar-wai", "Almodóvar", "Fellini", "Studio Ghibli", "Iranian cinema", "Festival circuit", "Criterion"]),
        .init(label: "Vinyl & World Music", subChips: ["Bossa Nova", "Afrobeat", "City Pop", "Cumbia", "Tropicália", "Folk", "Crate digging", "DJing", "Indie labels", "Concert tours"]),
        .init(label: "Slow Travel", subChips: ["Long stays", "Trains", "Backpacking", "Couchsurfing", "Workaways", "Hostels", "Off-grid", "Solo travel", "Walking tours", "House sitting"]),
        .init(label: "World Literature", subChips: ["Borges", "Murakami", "Calvino", "Tolstoy", "Pamuk", "Translated fiction", "Poetry", "Magical realism", "Short stories", "Memoir"]),
        .init(label: "Global Cuisine", subChips: ["Ramen", "Tagine", "Curry", "Mezze", "Banchan", "Fermentation", "Street food", "Markets", "Cooking classes", "Food tours"]),
        .init(label: "Film Photography", subChips: ["35mm", "Medium format", "Street", "Portrait", "Travel", "Architecture", "Markets", "Festivals", "Darkroom", "Zines"]),
        .init(label: "Language Exchange", subChips: ["Tandems", "italki", "Meetups", "Pen pals", "Conversation clubs", "Slang", "Pronunciation", "Calligraphy", "Idioms", "Code-switching"]),
        .init(label: "Fashion & Design", subChips: ["Streetwear", "Vintage", "Tokyo style", "Milanese tailoring", "Berlin techno", "Sneakers", "Concept stores", "Magazines", "Capsule wardrobes", "Editorial photography"]),
        .init(label: "Outdoor & Surf", subChips: ["Bali", "Portugal", "Costa Rica", "Nazaré", "Hiking", "Climbing", "Bouldering", "Trail running", "Diving", "Camping"])
    ]

    // Build the lookup once at app load via a static lazy var. Maps a
    // parent chip's label → its hardcoded sub-chips, with case-insensitive
    // dictionary keys via lowercased lookup.
    fileprivate static let professionLookup: (String) -> [String]? = makeLookup(from: professions)
    fileprivate static let hobbyLookup: (String) -> [String]? = makeLookup(from: hobbies)

    private static func makeLookup(from categories: [InterestCategory]) -> (String) -> [String]? {
        let dict = Dictionary(uniqueKeysWithValues: categories.map { ($0.label, $0.subChips) })
        return { label in dict[label] }
    }
}
