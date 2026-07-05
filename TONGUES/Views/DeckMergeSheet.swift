import SwiftUI

// "Merge into…" sheet shown from the deck detail menu. Lists the user's
// other decks that share this deck's language + dialect, and on selection
// copies every item from the current deck into the chosen target. The
// source deck is left untouched — only the target deck grows.
struct DeckMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
    // Reports the title of the deck the items were merged into so the
    // caller can surface a confirmation.
    let onMerged: (String) -> Void

    @State private var candidates: [DeckDocument] = []
    @State private var isLoading = true
    @State private var mergingId: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Color.white.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Merge into")
                                .font(.custom("PlayfairDisplay-Regular", size: 28))
                                .tracking(-1.5)
                                .foregroundStyle(.black)
                                .padding(.top, 40)

                            Text("Add all \(deck.items.count) \(deck.contentType.lowercased()) from \"\(deck.title)\" into another \(deck.language) (\(deck.dialect)) deck. This deck stays as is.")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if isLoading {
                            loadingState
                        } else if candidates.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 10) {
                                ForEach(candidates) { candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }

                closeButton
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("Couldn't merge", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await loadCandidates() }
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
        .disabled(mergingId != nil)
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
            Text("No decks to merge into")
                .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                .foregroundStyle(.black)
            Text("You don't have another \(deck.language) (\(deck.dialect)) deck yet. Create one in the same language and dialect, then merge into it.")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func candidateRow(_ candidate: DeckDocument) -> some View {
        Button {
            Haptics.medium()
            Task { await merge(into: candidate) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text("\(candidate.level) · \(candidate.items.count) \(candidate.contentType.lowercased())")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if mergingId == candidate.id {
                    ProgressView().tint(.black.opacity(0.5))
                } else {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15))
                        .foregroundStyle(.black)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mergingId != nil)
    }

    // Loads the user's decks and keeps only those that share this deck's
    // language + dialect, excluding the deck itself.
    private func loadCandidates() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await FirebaseDeckService.fetchDecks()
            candidates = all.filter { other in
                other.id != deck.id
                && other.language == deck.language
                && other.dialect == deck.dialect
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func merge(into target: DeckDocument) async {
        guard let targetId = target.id, mergingId == nil else { return }
        mergingId = targetId
        defer { mergingId = nil }
        do {
            try await FirebaseDeckService.addItems(
                toDeck: targetId,
                items: deck.items,
                sourceLanguage: deck.language
            )
            Haptics.success()
            onMerged(target.title)
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
