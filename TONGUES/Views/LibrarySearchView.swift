import SwiftUI

// Full-screen library search (Yelp-style): tapping the Library search
// bar presents this over the page. It owns its own navigation stack so
// tapping a result pushes the deck's detail right here; Cancel dismisses
// the whole cover. Searches across deck title, language/dialect, and the
// words inside each deck — both the target form and the native
// translation. A word result routes to the deck that contains it.
struct LibrarySearchView: View {
    let decks: [DeckDocument]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path = NavigationPath()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchHeader
                Divider()
                resultsArea
                Spacer(minLength: 0)
            }
            // Pin the field to the very top from the start — without an
            // explicit fill the short empty-state content would let the
            // VStack center itself ~⅓ down until results filled it out.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DeckDocument.self) { deck in
                DeckDetailView(deck: deck)
            }
        }
        // Focus the field as the screen appears so the keyboard is ready
        // immediately, matching the tap-to-search expectation.
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            fieldFocused = true
        }
    }

    // MARK: Header (field + Cancel)

    private var searchHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("Search decks, languages, words…", text: $query)
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .foregroundStyle(.black)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($fieldFocused)
                if !query.isEmpty {
                    Button {
                        Haptics.light()
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(white: 0.95)))

            Button {
                Haptics.light()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if trimmedQuery.isEmpty {
            emptyPrompt
        } else if deckResults.isEmpty && wordResults.isEmpty {
            noResults
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !deckResults.isEmpty {
                        sectionHeader("Decks")
                        ForEach(deckResults) { deck in
                            NavigationLink(value: deck) {
                                deckResultRow(deck)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                    if !wordResults.isEmpty {
                        sectionHeader("Words")
                        ForEach(wordResults) { hit in
                            NavigationLink(value: hit.deck) {
                                wordResultRow(hit)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color(white: 0.7))
            Text("Search your library by deck, language, or any word — in either language.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 60)
    }

    private var noResults: some View {
        Text("No matches for “\(trimmedQuery)”.")
            .font(.custom("NeueHaasDisplay-Light", size: 14))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 60)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.custom("NeueHaasDisplay-Light", size: 11))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    private func deckResultRow(_ deck: DeckDocument) -> some View {
        HStack(alignment: .center, spacing: 16) {
            DeckCoverFill(style: deck.resolvedCoverStyle)
                .frame(width: 60, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 6) {
                Text(deck.title)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(deck.language) | \(deck.level)")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func wordResultRow(_ hit: WordHit) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.item.word)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(hit.item.translation)
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("in \(hit.deck.title)")
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: Matching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Decks whose title, language, or dialect match the query.
    private var deckResults: [DeckDocument] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return decks.filter { deck in
            deck.title.lowercased().contains(q)
                || deck.language.lowercased().contains(q)
                || deck.dialect.lowercased().contains(q)
        }
    }

    // A single word inside a deck that matched, paired with its deck so
    // tapping routes to the deck that contains it.
    struct WordHit: Identifiable {
        let deck: DeckDocument
        let item: GeneratedItem
        var id: String { (deck.id ?? "") + "|" + item.id.uuidString }
    }

    // Words (target or native side) matching the query, deduped per
    // (deck, word) and capped so a broad query can't build a runaway
    // list.
    private var wordResults: [WordHit] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var hits: [WordHit] = []
        let limit = 80
        for deck in decks {
            for item in deck.items {
                if hits.count >= limit { return hits }
                let word = item.word.lowercased()
                let translation = item.translation.lowercased()
                guard word.contains(q) || translation.contains(q) else { continue }
                let key = (deck.id ?? "") + "|" + word
                if seen.insert(key).inserted {
                    hits.append(WordHit(deck: deck, item: item))
                }
            }
        }
        return hits
    }
}
