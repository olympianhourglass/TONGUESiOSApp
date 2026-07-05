import SwiftUI

// "Rename" sheet shown from the deck detail menu. Pre-fills the current
// title so the user can edit it directly, and — because a deck's items
// can drift from what its original title described (merges, camera finds,
// generate-more) — asks Haiku for one refreshed title suggestion based on
// the deck's CURRENT contents. Tapping the suggestion drops it into the
// field; the user is always free to type their own. Matches the app's
// sheet chrome: Playfair heading, Neue Haas body, glass close button,
// solid-black primary CTA.
struct DeckRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
    // Reports the newly-saved title so the caller can update its local
    // copy without a navigation round-trip.
    let onRenamed: (String) -> Void

    @State private var title: String
    @State private var suggestion: String?
    @State private var isSuggesting = true
    @State private var isSaving = false
    @State private var errorText: String?
    @FocusState private var isFieldFocused: Bool

    init(deck: DeckDocument, onRenamed: @escaping (String) -> Void) {
        self.deck = deck
        self.onRenamed = onRenamed
        self._title = State(initialValue: deck.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Color.white.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Rename")
                                .font(.custom("PlayfairDisplay-Regular", size: 28))
                                .tracking(-1.5)
                                .foregroundStyle(.black)
                                .padding(.top, 40)

                            Text("Give this \(deck.language) (\(deck.dialect)) deck a new title, or use the fresh one we suggest from its current \(deck.items.count) \(deck.contentType.lowercased()).")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        titleField
                        suggestionRow
                        saveButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }

                closeButton
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("Couldn't rename", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await loadSuggestion() }
    }

    // MARK: Title field

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TITLE")
                .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            TextField("Deck title", text: $title, axis: .vertical)
                .font(.custom("NeueHaasDisplay-Mediu", size: 24))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($isFieldFocused)
                .submitLabel(.done)
            Divider()
            Text("\(deck.level) · \(deck.items.count) \(deck.contentType.lowercased())")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Suggestion

    // A tappable pill offering the AI-refreshed title. Hidden once the
    // field already holds the suggestion (nothing left to apply) so it
    // never reads as redundant.
    @ViewBuilder
    private var suggestionRow: some View {
        if isSuggesting {
            HStack(spacing: 8) {
                ProgressView().tint(.black.opacity(0.5)).scaleEffect(0.8)
                Text("Thinking of a fresh title…")
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
            }
        } else if let suggestion, suggestion != trimmedTitle {
            VStack(alignment: .leading, spacing: 8) {
                Text("SUGGESTED")
                    .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        title = suggestion
                    }
                    isFieldFocused = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(.black)
                        Text(suggestion)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                            .foregroundStyle(.black)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text("Use")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            Haptics.medium()
            Task { await save() }
        } label: {
            HStack {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Save")
                        .font(.custom("PlayfairDisplay-Regular", size: 20))
                        .tracking(-1.2)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.black.opacity(trimmedTitle.isEmpty ? 0.35 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(trimmedTitle.isEmpty || isSaving)
        .padding(.top, 4)
    }

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.top, 16)
        .padding(.trailing, 8)
        .disabled(isSaving)
    }

    // MARK: Actions

    private func loadSuggestion() async {
        isSuggesting = true
        defer { isSuggesting = false }
        // A failed suggestion is non-fatal — the user can still type their
        // own title, so we just quietly drop it.
        suggestion = try? await DeckGenerator.suggestDeckTitle(for: deck)
    }

    private func save() async {
        guard let deckId = deck.id, !trimmedTitle.isEmpty, !isSaving else { return }
        // No change → nothing to write; just close.
        guard trimmedTitle != deck.title else {
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FirebaseDeckService.renameDeck(deckId: deckId, title: trimmedTitle)
            Haptics.success()
            onRenamed(trimmedTitle)
            dismiss()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }
}
