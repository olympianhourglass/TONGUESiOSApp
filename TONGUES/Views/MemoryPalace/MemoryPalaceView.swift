import SwiftUI

// The Memory Palace home: a 2D floor-plan of the user's palace. Rooms sit
// on a grid; the user grows the palace outward by tapping the ⊕ ghost tiles
// that appear around a selected room (the "fractal" extension), assigns a
// deck to each room, and can jump into a 3D walkthrough of the same plan.
struct MemoryPalaceView: View {
    @State private var store = MemoryPalaceStore.shared

    // The full deck list, loaded once and shared with the room editor (for
    // assignment) and the 3D walkthrough (for the words on the walls).
    @State private var decks: [DeckDocument] = []
    @State private var isLoadingDecks = false

    @State private var selectedRoomID: UUID?
    @State private var editingRoom: PalaceRoom?
    @State private var showRenamePalace = false
    @State private var palaceNameDraft = ""
    // The 3D walkthrough is presented full-screen (not inside the profile
    // sheet) so it fills the whole display.
    @State private var show3D = false
    // Which story the 2D map is currently showing/editing. Stairs link rooms
    // that share an (x, y) across adjacent floors.
    @State private var currentFloor = 0

    // Grid geometry. `pitch` is the centre-to-centre spacing between cells;
    // the tile is a little smaller so neighbouring rooms read as separate
    // rooms joined by a doorway rather than one continuous slab.
    private let pitch: CGFloat = 116
    private let tile: CGFloat = 96

    private var decksById: [String: DeckDocument] {
        Dictionary(uniqueKeysWithValues: decks.compactMap { deck in
            deck.id.map { ($0, deck) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .trailing) {
                mapScroll
                floorRail
                    .padding(.trailing, 10)
            }
            // Stairs (stories) attach to rooms only — the hallway stays flat.
            if let selection = activeSelection, !selection.isHallway {
                storyControls
            }
            footer
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .navigationTitle(L("Memory Palace"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        palaceNameDraft = store.palace.name
                        showRenamePalace = true
                    } label: {
                        Label(L("Rename palace"), systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tint(.white)
                }
            }
        }
        .task {
            store.reload()
            await loadDecks()
        }
        .onChange(of: store.palace.floors) { _, floors in
            // Keep the viewed story valid if its last room was deleted.
            if !floors.contains(currentFloor) { currentFloor = floors.first ?? 0 }
        }
        .sheet(item: $editingRoom) { room in
            MemoryPalaceRoomSheet(room: room, store: store, decks: decks)
        }
        .alert(L("Rename palace"), isPresented: $showRenamePalace) {
            TextField(L("Palace name"), text: $palaceNameDraft)
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) { store.renamePalace(palaceNameDraft) }
        }
        .fullScreenCover(isPresented: $show3D) {
            NavigationStack {
                MemoryPalace3DView(store: store, decks: decks)
            }
            // The planning screen is dark; the 3D walkthrough stays light so its
            // white rooms, chips, and nav bar read as designed.
            .preferredColorScheme(.light)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.palace.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(floorLabel(currentFloor))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(instructionText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // Context-sensitive hint under the palace name.
    private var instructionText: String {
        guard let selection = activeSelection else {
            return L("Tap the hallway or a room, then ⊕ to extend. The hallway runs north–south; rooms branch off its sides.")
        }
        if selection.isHallway {
            return L("Tap ⊕ north/south to extend the hallway · east/west to add a room · ↑/↓ for stairs.")
        }
        return L("Tap ⊕ to add a room · ↑/↓ for stairs · tap the room again to edit.")
    }

    // MARK: Map

    private var mapScroll: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            mapCanvas
                .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Rooms on the story currently being viewed/edited.
    private var floorRooms: [PalaceRoom] {
        store.rooms.filter { $0.floor == currentFloor }
    }

    // Bounds padded by one cell on every side so a selected edge room always
    // has room on-canvas to show its ⊕ ghost tiles. Scoped to the current
    // floor's rooms.
    private var bounds: (minX: Int, minY: Int, cols: Int, rows: Int) {
        let xs = floorRooms.map(\.x)
        let ys = floorRooms.map(\.y)
        let minX = (xs.min() ?? 0) - 1
        let maxX = (xs.max() ?? 0) + 1
        let minY = (ys.min() ?? 0) - 1
        let maxY = (ys.max() ?? 0) + 1
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private func center(x: Int, y: Int) -> CGPoint {
        let b = bounds
        return CGPoint(
            x: CGFloat(x - b.minX) * pitch + pitch / 2,
            y: CGFloat(y - b.minY) * pitch + pitch / 2
        )
    }

    // A contiguous vertical hallway column on the current floor, rendered as one
    // long runner rectangle rather than separate cells.
    struct HallRun: Identifiable {
        let x: Int
        let minY: Int
        let maxY: Int
        var id: Int { x }
    }

    private var hallwaySpines: [HallRun] {
        let byColumn = Dictionary(grouping: floorRooms.filter { $0.isHallway }, by: \.x)
        return byColumn.map { x, cells in
            HallRun(x: x, minY: cells.map(\.y).min() ?? 0, maxY: cells.map(\.y).max() ?? 0)
        }
    }

    private func hallwaySpine(_ run: HallRun) -> some View {
        let top = center(x: run.x, y: run.minY)
        let bottom = center(x: run.x, y: run.maxY)
        return RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.22)))
            .frame(width: tile * 0.5, height: (bottom.y - top.y) + tile)
            .position(x: top.x, y: (top.y + bottom.y) / 2)
    }

    private var mapCanvas: some View {
        let b = bounds
        return ZStack {
            // The hallway as one continuous runner, drawn first so the corridor
            // reads as a single long rectangle beneath its segment tiles.
            ForEach(hallwaySpines) { run in
                hallwaySpine(run)
            }

            // Doorway connectors between connected rooms — drawn under the tiles.
            ForEach(connectorPairs, id: \.self) { pair in
                connector(from: pair.a, to: pair.b)
            }

            // Ghost ⊕ tiles for the selected room's empty neighbours.
            if let room = activeSelection {
                ForEach(emptyNeighbours(of: room), id: \.self) { cell in
                    ghostTile(at: cell, from: room)
                }
            }

            // The rooms on this floor.
            ForEach(floorRooms) { room in
                roomTile(room)
                    .position(center(x: room.x, y: room.y))
            }
        }
        .frame(
            width: CGFloat(b.cols) * pitch,
            height: CGFloat(b.rows) * pitch
        )
    }

    private var selectedRoom: PalaceRoom? {
        store.rooms.first { $0.id == selectedRoomID }
    }

    // The selection only counts on the story currently shown — switching
    // floors hides a selection that lives elsewhere.
    private var activeSelection: PalaceRoom? {
        guard let room = selectedRoom, room.floor == currentFloor else { return nil }
        return room
    }

    private func roomTile(_ room: PalaceRoom) -> some View {
        let isSelected = room.id == selectedRoomID
        return Button {
            Haptics.light()
            if isSelected {
                // Hallway segments are structural circulation — no deck editor.
                if !room.isHallway { editingRoom = room }
            } else {
                selectedRoomID = room.id
            }
        } label: {
            if room.isHallway {
                hallwayTileLabel(room, isSelected: isSelected)
            } else {
                deckRoomTileLabel(room, isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
    }

    private func deckRoomTileLabel(_ room: PalaceRoom, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Text(room.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let title = room.deckTitle {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Label(L("Empty"), systemImage: "plus.rectangle.on.folder")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15))
                    .foregroundStyle(.black.opacity(0.35))
            }
        }
        .padding(8)
        .frame(width: tile, height: tile)
        .background(
            Color(uiColor: MemoryPalace.uiColor(forIndex: room.colorIndex)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.black : Color.black.opacity(0.12),
                        lineWidth: isSelected ? 2.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            // Stair-link badges: this room connects up and/or down.
            VStack(spacing: 2) {
                if store.palace.hasRoomAbove(room) {
                    Image(systemName: "chevron.up")
                }
                if store.palace.hasRoomBelow(room) {
                    Image(systemName: "chevron.down")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black.opacity(0.4))
            .padding(6)
        }
    }

    // A hallway segment tap target sitting over the continuous spine: just a
    // walk marker, plus a highlight ring when selected. The filled runner is
    // drawn once behind all segments by `hallwaySpine`.
    private func hallwayTileLabel(_ room: PalaceRoom, isSelected: Bool) -> some View {
        Image(systemName: "figure.walk")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: tile * 0.5, height: tile)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2.5)
            )
            .frame(width: tile, height: tile)
            .contentShape(Rectangle())
    }

    private func ghostTile(at cell: GridCell, from room: PalaceRoom) -> some View {
        Button {
            Haptics.medium()
            if let new = store.extend(from: room, direction: cell.direction) {
                selectedRoomID = new.id
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: tile, height: tile)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(.white.opacity(0.3))
                )
        }
        .buttonStyle(.plain)
        .position(center(x: cell.x, y: cell.y))
    }

    private func connector(from a: GridCell, to b: GridCell) -> some View {
        let p1 = center(x: a.x, y: a.y)
        let p2 = center(x: b.x, y: b.y)
        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        let horizontal = a.y == b.y
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.18))
            .frame(
                width: horizontal ? pitch - tile + 8 : 14,
                height: horizontal ? 14 : pitch - tile + 8
            )
            .position(mid)
    }

    // MARK: Footer

    private var footer: some View {
        Button {
            Haptics.light()
            show3D = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 16, weight: .semibold))
                Text(L("Walk through in 3D"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Floors

    // Vertical rail of the palace's existing stories (top = highest). Tapping
    // switches which story the map shows. Hidden until there's more than one.
    private var floorRail: some View {
        let floors = store.palace.floors
        return VStack(spacing: 6) {
            ForEach(floors.reversed(), id: \.self) { floor in
                Button {
                    Haptics.light()
                    currentFloor = floor
                } label: {
                    Text(floorLabel(floor, short: true))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(floor == currentFloor ? .black : .white)
                        .frame(width: 36, height: 30)
                        .background(
                            floor == currentFloor ? Color.white : Color.white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(floors.count > 1 ? 1 : 0)
    }

    // Stair controls for the selected room: go to (or create) the room
    // directly above / below it, linked by stairs.
    private var storyControls: some View {
        let selection = activeSelection
        let hasAbove = selection.map { store.palace.hasRoomAbove($0) } ?? false
        let hasBelow = selection.map { store.palace.hasRoomBelow($0) } ?? false
        return HStack(spacing: 10) {
            storyButton(
                title: hasAbove ? L("Go upstairs") : L("Add story above"),
                systemImage: "arrow.up.to.line",
                up: true
            )
            storyButton(
                title: hasBelow ? L("Go downstairs") : L("Add story below"),
                systemImage: "arrow.down.to.line",
                up: false
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func storyButton(title: String, systemImage: String, up: Bool) -> some View {
        Button {
            goVertical(up: up)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Move to the story above/below the selected room — creating the linked
    // room the first time, then selecting it on the newly-shown floor.
    private func goVertical(up: Bool) {
        guard let selection = activeSelection else { return }
        Haptics.medium()
        let targetFloor = selection.floor + (up ? 1 : -1)
        if let existing = store.palace.room(at: selection.x, selection.y, floor: targetFloor) {
            currentFloor = targetFloor
            selectedRoomID = existing.id
        } else if let new = store.extendVertical(from: selection, up: up) {
            currentFloor = targetFloor
            selectedRoomID = new.id
        }
    }

    // Human-readable story name. Ground floor reads as "Floor 1"; stories below
    // ground read as basements.
    private func floorLabel(_ floor: Int, short: Bool = false) -> String {
        if floor >= 0 {
            return short ? "\(floor + 1)F" : L("Floor %d", floor + 1)
        } else {
            return short ? "B\(-floor)" : L("Basement %d", -floor)
        }
    }

    // MARK: Grid helpers

    // A grid cell, optionally tagged with the direction that reached it from
    // the room being extended (used only for ghost tiles).
    struct GridCell: Hashable {
        let x: Int
        let y: Int
        var direction: PalaceDirection = .north
    }

    struct ConnectorPair: Hashable {
        let a: GridCell
        let b: GridCell
    }

    private func emptyNeighbours(of room: PalaceRoom) -> [GridCell] {
        PalaceDirection.allCases.compactMap { dir in
            // Rooms only extend perpendicular to the hallway (east/west); adding
            // a room parallel to the corridor (north/south) isn't allowed. The
            // hallway itself still extends along its axis and spins off rooms.
            if !room.isHallway && (dir == .north || dir == .south) { return nil }
            let nx = room.x + dir.delta.dx
            let ny = room.y + dir.delta.dy
            guard !store.palace.isOccupied(nx, ny, floor: room.floor) else { return nil }
            return GridCell(x: nx, y: ny, direction: dir)
        }
    }

    // Doorway connectors: only between genuinely CONNECTED cells (a real
    // doorway), never between merely-adjacent sibling rooms. The continuous
    // hallway spine draws itself, so hallway↔hallway pairs are skipped here.
    // East + south sweep avoids drawing each shared edge twice.
    private var connectorPairs: [ConnectorPair] {
        var pairs: [ConnectorPair] = []
        for room in floorRooms {
            for dir in [PalaceDirection.east, .south] {
                let nx = room.x + dir.delta.dx
                let ny = room.y + dir.delta.dy
                guard let neighbour = store.palace.room(at: nx, ny, floor: currentFloor),
                      store.palace.isConnected(room, neighbour),
                      !(room.isHallway && neighbour.isHallway) else { continue }
                pairs.append(ConnectorPair(
                    a: GridCell(x: room.x, y: room.y),
                    b: GridCell(x: nx, y: ny)
                ))
            }
        }
        return pairs
    }

    // MARK: Data

    private func loadDecks() async {
        isLoadingDecks = true
        defer { isLoadingDecks = false }
        decks = (try? await FirebaseDeckService.fetchDecks()) ?? []
    }
}
