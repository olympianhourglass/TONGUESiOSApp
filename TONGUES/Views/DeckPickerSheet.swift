import SwiftUI

struct DeckPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let itemsToAdd: [GeneratedItem]
    let sourceLanguage: String
    let sourceDialect: String
    let onAdded: () -> Void

    @State private var decks: [DeckDocument] = []
    @State private var isLoading = false
    @State private var addingDeckId: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to deck")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(addingDeckId != nil)
                    }
                }
                .task { await load() }
                .alert("Couldn't add to deck", isPresented: errorBinding) {
                    Button("OK") { errorText = nil }
                } message: {
                    Text(errorText ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && decks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if decks.isEmpty {
            ContentUnavailableView {
                Label("No matching decks", systemImage: "books.vertical")
            } description: {
                Text("No \(sourceLanguage) (\(sourceDialect)) decks yet — tap \"Create New Deck\" to save this as a new one.")
            }
        } else {
            List {
                ForEach(decks) { deck in
                    Button {
                        Task { await add(to: deck) }
                    } label: {
                        HStack {
                            DeckRow(deck: deck)
                            Spacer()
                            if addingDeckId == deck.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(addingDeckId != nil)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Only surface decks whose language + dialect match the
            // generation we're adding from — adding French (Parisian) cards
            // into a Spanish deck (or even into French (Quebec)) would mix
            // incompatible content.
            let all = try await FirebaseDeckService.fetchDecks()
            decks = all.filter {
                $0.language == sourceLanguage && $0.dialect == sourceDialect
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func add(to deck: DeckDocument) async {
        guard let id = deck.id else { return }
        Haptics.light()
        addingDeckId = id
        defer { addingDeckId = nil }
        do {
            try await FirebaseDeckService.addItems(
                toDeck: id,
                items: itemsToAdd,
                sourceLanguage: sourceLanguage
            )
            Haptics.success()
            dismiss()
            onAdded()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }
}
