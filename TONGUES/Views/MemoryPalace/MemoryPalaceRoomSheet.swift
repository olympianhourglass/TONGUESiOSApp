import SwiftUI

// Editor for a single palace room: rename it, pick its colour, assign the
// deck the room memorises (and preview that deck's words), or remove the
// room from the palace. Mutations flow straight through the shared store so
// the map and 3D walkthrough pick them up.
struct MemoryPalaceRoomSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var room: PalaceRoom
    let store: MemoryPalaceStore
    let decks: [DeckDocument]

    @State private var choosingDeck = false
    @State private var deckSearch = ""

    init(room: PalaceRoom, store: MemoryPalaceStore, decks: [DeckDocument]) {
        _room = State(initialValue: room)
        self.store = store
        self.decks = decks
    }

    private var assignedDeck: DeckDocument? {
        guard let id = room.deckId else { return nil }
        return decks.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if choosingDeck {
                    deckChooser
                } else {
                    roomEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(choosingDeck ? L("Assign a deck") : room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if choosingDeck {
                        Button(L("Back")) { choosingDeck = false }
                            .tint(.white)
                    } else {
                        Button(L("Done")) { dismiss() }
                            .tint(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Room editor

    private var roomEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                nameField
                colorPicker
                deckSection
                if store.rooms.count > 1 {
                    removeButton
                }
            }
            .padding(20)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("Room name"))
            TextField(L("Room name"), text: $room.name)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: room.name) { _, _ in store.update(room) }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("Room colour"))
            HStack(spacing: 10) {
                ForEach(MemoryPalace.paletteHexes.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(uiColor: MemoryPalace.uiColor(forIndex: index)))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle().stroke(
                                index == room.colorIndex ? Color.white : Color.white.opacity(0.3),
                                lineWidth: index == room.colorIndex ? 2.5 : 1
                            )
                        )
                        .onTapGesture {
                            Haptics.light()
                            room.colorIndex = index
                            store.update(room)
                        }
                }
            }
        }
    }

    private var deckSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("Deck in this room"))
            if let deck = assignedDeck {
                assignedDeckCard(deck)
            } else {
                Button {
                    Haptics.light()
                    choosingDeck = true
                } label: {
                    Label(L("Assign a deck"), systemImage: "rectangle.stack.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func assignedDeckCard(_ deck: DeckDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(L("%d words · %@", deck.items.count, localizedLanguageName(deck.language)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(L("Change deck")) { choosingDeck = true }
                    Button(L("Remove deck"), role: .destructive) {
                        store.clearDeck(from: room.id)
                        room.deckId = nil
                        room.deckTitle = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }

            if !deck.items.isEmpty {
                Divider()
                // Preview the words that will line the room's walls in 3D.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(deck.items.prefix(12)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.word)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                            Text(item.translation)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if deck.items.count > 12 {
                        Text(L("+%d more", deck.items.count - 12))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            Haptics.medium()
            store.removeRoom(room.id)
            dismiss()
        } label: {
            Label(L("Remove room"), systemImage: "trash")
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
    }

    // MARK: Deck chooser

    private var filteredDecks: [DeckDocument] {
        let trimmed = deckSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return decks }
        return decks.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var deckChooser: some View {
        Group {
            if decks.isEmpty {
                ContentUnavailableView {
                    Label(L("No decks yet"), systemImage: "books.vertical")
                } description: {
                    Text(L("Create a deck in your library first, then assign it to this room."))
                }
            } else {
                List {
                    ForEach(filteredDecks) { deck in
                        Button {
                            Haptics.success()
                            store.assignDeck(deck, to: room.id)
                            room.deckId = deck.id
                            room.deckTitle = deck.title
                            choosingDeck = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(deck.title)
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                    Text(L("%d words · %@", deck.items.count, localizedLanguageName(deck.language)))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if room.deckId == deck.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $deckSearch, prompt: L("Search decks"))
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
