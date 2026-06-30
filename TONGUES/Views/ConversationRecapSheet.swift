import SwiftUI

// Presented when the user ends a conversation. Claude summarizes the
// session and suggests 5–10 study-worthy phrases; the user toggles
// which to keep, then taps "Add to deck" to dump the selected ones
// into a deck via the existing DeckPickerSheet.
struct ConversationRecapSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isBuilding: Bool
    let recap: ConversationRecap?
    let language: String
    let dialect: String
    let onSaved: () -> Void
    let onDismiss: () -> Void

    @State private var phrases: [RecapPhrase] = []
    @State private var deckPickerOpen = false

    var body: some View {
        NavigationStack {
            Group {
                if isBuilding {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Pulling together what you covered…")
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let recap, !phrases.isEmpty {
                    recapContent(recap)
                } else {
                    ContentUnavailableView(
                        "Nothing to recap yet",
                        systemImage: "checkmark.seal",
                        description: Text("Have a bit more of a conversation, then come back.")
                    )
                }
            }
            .navigationTitle("Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { onDismiss() }
                }
            }
            .sheet(isPresented: $deckPickerOpen) {
                DeckPickerSheet(
                    itemsToAdd: selectedItems,
                    sourceLanguage: language,
                    sourceDialect: dialect,
                    onAdded: {
                        deckPickerOpen = false
                        onSaved()
                    }
                )
            }
            .onChange(of: recap?.phrases) { _, newValue in
                phrases = newValue ?? []
            }
        }
    }

    private func recapContent(_ recap: ConversationRecap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(recap.summary)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Divider()
                    .padding(.horizontal, 16)

                Text("PHRASES TO KEEP")
                    .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                VStack(spacing: 8) {
                    ForEach(Array(phrases.enumerated()), id: \.element.id) { idx, phrase in
                        recapRow(phrase, index: idx)
                    }
                }
                .padding(.horizontal, 16)

                Button {
                    Haptics.medium()
                    deckPickerOpen = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Add \(selectedItems.count) to deck")
                            .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(selectedItems.isEmpty ? Color.black.opacity(0.4) : Color.black)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedItems.isEmpty)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    private func recapRow(_ phrase: RecapPhrase, index: Int) -> some View {
        Button {
            Haptics.light()
            phrases[index].isSelected.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: phrase.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(phrase.isSelected ? .black : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(phrase.foreign)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(.black)
                    if let translit = phrase.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    Text(phrase.translation)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedItems: [GeneratedItem] {
        phrases
            .filter { $0.isSelected }
            .map { $0.asGeneratedItem(language: language) }
    }
}
