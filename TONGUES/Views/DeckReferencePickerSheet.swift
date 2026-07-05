import SwiftUI

// Multi-select picker for attaching existing decks as reference material
// on the Generate form. The learner picks one or more of their decks;
// their titles + sampled items are then fed into the generation prompt so
// the model can match style, extend themes, or adapt them across
// languages. Matches the app's sheet chrome (Playfair heading, glass
// close button, Neue Haas body) — same shape as DeckMergeSheet.
struct DeckReferencePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Decks already attached, so the picker opens with them checked.
    let initiallySelected: [DeckDocument]
    // Returns the final selection when the user taps Done.
    let onDone: ([DeckDocument]) -> Void

    @State private var decks: [DeckDocument] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = true
    @State private var errorText: String?

    // Attaching every deck would blow the prompt's token budget, so cap
    // the selection — mirrors the per-generation cap in DeckGenerator.
    private let maxSelection = 3

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Color.white.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Reference decks")
                                .font(.custom("PlayfairDisplay-Regular", size: 28))
                                .tracking(-1.5)
                                .foregroundStyle(.black)
                                .padding(.top, 40)

                            Text("Pick up to \(maxSelection) of your decks to guide this generation. The model matches their style and themes, and can adapt decks from other languages.")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if isLoading {
                            loadingState
                        } else if decks.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 10) {
                                ForEach(decks) { deck in
                                    deckRow(deck)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }

                closeButton
            }
            .safeAreaInset(edge: .bottom) {
                if !decks.isEmpty {
                    doneButton
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("Couldn't load your decks", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await load() }
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
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView().tint(.black.opacity(0.5))
            Spacer()
        }
        .padding(.vertical, 48)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.black.opacity(0.25))
            Text("No decks to reference yet")
                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                .foregroundStyle(.black)
            Text("Create a deck first, then you can reference it here to guide future generations.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func deckRow(_ deck: DeckDocument) -> some View {
        let id = deck.id ?? ""
        let isSelected = selectedIDs.contains(id)
        return Button {
            Haptics.light()
            toggle(deck)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.title)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text("\(deck.language) · \(deck.level) · \(deck.items.count) \(deck.contentType.lowercased())")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .black : Color.black.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(isSelected ? Color.black.opacity(0.08) : Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var doneButton: some View {
        Button {
            Haptics.medium()
            let chosen = decks.filter { selectedIDs.contains($0.id ?? "") }
            onDone(chosen)
            dismiss()
        } label: {
            Text(selectedIDs.isEmpty ? "Done" : "Attach \(selectedIDs.count)")
                .font(.custom("PlayfairDisplay-Regular", size: 20))
                .tracking(-1.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    // Toggling respects the cap: selecting past the limit is a no-op with
    // an error haptic so the user notices the ceiling.
    private func toggle(_ deck: DeckDocument) {
        let id = deck.id ?? ""
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else if selectedIDs.count < maxSelection {
            selectedIDs.insert(id)
        } else {
            Haptics.error()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        selectedIDs = Set(initiallySelected.compactMap { $0.id })
        do {
            decks = try await FirebaseDeckService.fetchDecks()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }
}
