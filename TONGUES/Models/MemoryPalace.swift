import Foundation
import Observation
import FirebaseAuth
import UIKit

// MARK: - Model

// The four cardinal ways a room can be extended on the 2D grid. Grid y
// grows downward (screen convention) — north is up, south is down — and the
// same deltas drive the 3D layout (grid y maps to world z), so a doorway
// carved between two adjacent rooms lines up in both the map and the
// walkthrough.
enum PalaceDirection: String, CaseIterable, Identifiable {
    case north, east, south, west

    var id: String { rawValue }

    var delta: (dx: Int, dy: Int) {
        switch self {
        case .north: return (0, -1)
        case .east:  return (1, 0)
        case .south: return (0, 1)
        case .west:  return (-1, 0)
        }
    }

    // The opposite side, used to knock out the matching wall on the
    // neighbouring room so a shared doorway is a single continuous opening.
    var opposite: PalaceDirection {
        switch self {
        case .north: return .south
        case .east:  return .west
        case .south: return .north
        case .west:  return .east
        }
    }
}

// What a grid cell is: a `room` that memorizes a deck, or a `hallway`
// segment — a piece of the central corridor the user starts in and branches
// off. Hallways never hold a deck; they're pure circulation, in both the 2D
// map and the 3D walkthrough.
enum PalaceRoomKind: String, Codable {
    case room
    case hallway
}

// A single cell in the palace, pinned to an integer grid coordinate on a
// given floor (story). Cells are adjacent on the SAME floor when their (x, y)
// differ by exactly one step on a single axis — that drives the map's extend
// arrows and the 3D doorways. Cells on adjacent floors sharing the same (x, y)
// are linked by stairs, which is how the palace grows a second/third story.
struct PalaceRoom: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var x: Int
    var y: Int
    // Story index. 0 is the ground floor; higher numbers stack upward. Optional
    // on decode so palaces saved before multi-story support load as all-ground.
    var floor: Int
    // Firestore deck id this room memorizes. Nil = a room the user has
    // carved out but not yet filled with a deck.
    var deckId: String?
    // Cached deck title so the map and 3D can label the room without a
    // fetch; refreshed whenever a deck is (re)assigned.
    var deckTitle: String?
    // Index into `MemoryPalace.paletteHexes` for the room's tile + 3D walls,
    // so each room reads distinctly at a glance.
    var colorIndex: Int
    // Whether this cell is a deck room or a hallway corridor segment.
    var kind: PalaceRoomKind
    // The cell this one was carved out of (its neighbour along the shared
    // doorway). This is what makes a wall a DOOR: a doorway is only opened
    // along a parent↔child edge, so sibling rooms that merely sit next to each
    // other stay walled off. Nil for the first cell / stair-linked cells.
    var parentID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        x: Int,
        y: Int,
        floor: Int = 0,
        deckId: String? = nil,
        deckTitle: String? = nil,
        colorIndex: Int = 0,
        kind: PalaceRoomKind = .room,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.floor = floor
        self.deckId = deckId
        self.deckTitle = deckTitle
        self.colorIndex = colorIndex
        self.kind = kind
        self.parentID = parentID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, x, y, floor, deckId, deckTitle, colorIndex, kind, parentID
    }

    // Custom decode so `floor` defaults to 0 for palaces persisted before
    // stories existed and `kind` defaults to `.room` for palaces saved before
    // hallways existed; everything else decodes as usual. Encoding stays
    // synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        x = try c.decode(Int.self, forKey: .x)
        y = try c.decode(Int.self, forKey: .y)
        floor = try c.decodeIfPresent(Int.self, forKey: .floor) ?? 0
        deckId = try c.decodeIfPresent(String.self, forKey: .deckId)
        deckTitle = try c.decodeIfPresent(String.self, forKey: .deckTitle)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        kind = try c.decodeIfPresent(PalaceRoomKind.self, forKey: .kind) ?? .room
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
    }

    var hasDeck: Bool { deckId != nil }
    var isHallway: Bool { kind == .hallway }
}

// A user's memory palace: a connected cluster of rooms on a shared grid.
// The basics ship a single palace per user, persisted locally.
struct MemoryPalace: Codable, Hashable {
    var name: String
    var rooms: [PalaceRoom]
    var createdAt: Date

    init(name: String = "My Memory Palace", rooms: [PalaceRoom] = [], createdAt: Date = Date()) {
        self.name = name
        self.rooms = rooms
        self.createdAt = createdAt
    }

    // Length of a fresh starter hallway, in grid segments.
    static let starterHallwayLength = 3

    // A brand-new palace starts as a short central hallway running north–south
    // at x = 0. The user spawns at its south end (the entrance) and branches
    // rooms off to the east and west. The map is never empty.
    static func starter() -> MemoryPalace {
        var hall: [PalaceRoom] = []
        for y in 0..<starterHallwayLength {
            // Chain each segment to the previous so the whole corridor is one
            // connected, open run.
            let parent = hall.last?.id
            hall.append(PalaceRoom(name: "Hallway", x: 0, y: y, floor: 0, colorIndex: 0, kind: .hallway, parentID: parent))
        }
        return MemoryPalace(rooms: hall)
    }

    // Muted, distinct tile colours cycled by `colorIndex`. Hex strings so the
    // palette lives in the model and both the SwiftUI map and the SceneKit
    // walkthrough resolve the same colour for a given room.
    static let paletteHexes: [String] = [
        "E8E2D5", // sand
        "D9E4DD", // sage
        "DDE1EC", // slate blue
        "ECD9DD", // rose
        "E4DDEC", // lavender
        "E7E7DE"  // stone
    ]

    // Resolves a room's palette entry to a UIColor so the SwiftUI map
    // (via Color(uiColor:)) and the SceneKit walkthrough share one source
    // of truth for room colours. Falls back to the first swatch on a bad
    // index rather than crashing.
    static func uiColor(forIndex index: Int) -> UIColor {
        let hex = paletteHexes[((index % paletteHexes.count) + paletteHexes.count) % paletteHexes.count]
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    func room(at x: Int, _ y: Int, floor: Int) -> PalaceRoom? {
        rooms.first { $0.x == x && $0.y == y && $0.floor == floor }
    }

    func isOccupied(_ x: Int, _ y: Int, floor: Int) -> Bool {
        rooms.contains { $0.x == x && $0.y == y && $0.floor == floor }
    }

    // Two cells share a doorway only when one was carved out of the other
    // (a parent↔child edge). Adjacent-but-unrelated cells stay walled off.
    func isConnected(_ a: PalaceRoom, _ b: PalaceRoom) -> Bool {
        a.parentID == b.id || b.parentID == a.id
    }

    // Directions from `room` that lead to a CONNECTED neighbour on the SAME
    // floor — the openings the 3D walkthrough turns into doorways (or, between
    // two hallway segments, an open corridor). Mere adjacency is not enough:
    // sibling rooms hanging off the hallway don't open into each other.
    func openings(from room: PalaceRoom) -> Set<PalaceDirection> {
        var result: Set<PalaceDirection> = []
        for dir in PalaceDirection.allCases {
            guard let neighbour = self.room(at: room.x + dir.delta.dx, room.y + dir.delta.dy, floor: room.floor) else { continue }
            if isConnected(room, neighbour) {
                result.insert(dir)
            }
        }
        return result
    }

    // Stair links: a room connects upward/downward when a room shares its
    // (x, y) on the adjacent floor.
    func hasRoomAbove(_ room: PalaceRoom) -> Bool {
        isOccupied(room.x, room.y, floor: room.floor + 1)
    }

    func hasRoomBelow(_ room: PalaceRoom) -> Bool {
        isOccupied(room.x, room.y, floor: room.floor - 1)
    }

    // Sorted, de-duplicated list of the floors that currently have rooms.
    var floors: [Int] {
        Set(rooms.map(\.floor)).sorted()
    }

    func rooms(onFloor floor: Int) -> [PalaceRoom] {
        rooms.filter { $0.floor == floor }
    }

    // MARK: - Hallway

    var hasHallway: Bool {
        rooms.contains { $0.isHallway }
    }

    // The cell the 3D walkthrough spawns in: the south (highest-y) end of the
    // hallway on the lowest floor, so the user starts at the entrance looking
    // north up the corridor. Falls back to any lowest cell if there's no
    // hallway (shouldn't happen post-migration).
    func spawnCell() -> PalaceRoom? {
        let lowestFloor = rooms.map(\.floor).min() ?? 0
        let hall = rooms.filter { $0.isHallway && $0.floor == lowestFloor }
        if let entrance = hall.max(by: { $0.y < $1.y }) { return entrance }
        return rooms.min { ($0.floor, $0.y, $0.x) < ($1.floor, $1.y, $1.x) }
    }

    // Rebuilds a pre-hallway palace around a central hallway spine, re-hanging
    // the existing rooms — with their names, decks, and colours — off the
    // corridor's sides (alternating west/east down its length), per floor so
    // stairs still line up. Used to migrate palaces saved before hallways.
    func migratedToHallway() -> MemoryPalace {
        guard !hasHallway else { return self }
        var rebuilt: [PalaceRoom] = []
        let floorList = rooms.isEmpty ? [0] : Set(rooms.map(\.floor)).sorted()
        for floor in floorList {
            let floorRooms = rooms.filter { $0.floor == floor }
            // Enough hallway segments to hang every room off a side.
            let perSide = (floorRooms.count + 1) / 2
            let length = max(MemoryPalace.starterHallwayLength, perSide)
            // Build the corridor, chaining each segment to the previous one, and
            // remember which hallway id sits at each y so rooms can attach to it.
            var hallByY: [Int: UUID] = [:]
            var previous: UUID?
            for y in 0..<length {
                let cell = PalaceRoom(name: "Hallway", x: 0, y: y, floor: floor, colorIndex: 0, kind: .hallway, parentID: previous)
                hallByY[y] = cell.id
                previous = cell.id
                rebuilt.append(cell)
            }
            // West (x = -1) then east (x = +1), stepping down the hallway; each
            // room's doorway is its entry off the adjacent hallway segment.
            for (i, room) in floorRooms.enumerated() {
                let y = i / 2
                var moved = room
                moved.x = (i % 2 == 0) ? -1 : 1
                moved.y = y
                moved.floor = floor
                moved.kind = .room
                moved.parentID = hallByY[y]
                rebuilt.append(moved)
            }
        }
        var migrated = self
        migrated.rooms = rebuilt
        return migrated
    }

    // A hallway palace needs its connections (re)inferred when either it predates
    // `parentID` entirely, or its corridor isn't actually chained together — the
    // symptom of an earlier inference that rooted every hallway segment
    // separately, which leaves them walled off from one another.
    var needsConnectionInference: Bool {
        guard hasHallway else { return false }
        if rooms.count > 1 && rooms.allSatisfy({ $0.parentID == nil }) { return true }
        return hallwayCorridorBroken
    }

    // True if two adjacent hallway segments on the same floor aren't connected —
    // i.e. the corridor can't be walked end to end.
    private var hallwayCorridorBroken: Bool {
        for cell in rooms where cell.isHallway {
            for dir in [PalaceDirection.north, .south] {
                if let n = room(at: cell.x + dir.delta.dx, cell.y + dir.delta.dy, floor: cell.floor),
                   n.isHallway, !isConnected(cell, n) {
                    return true
                }
            }
        }
        return false
    }

    // Rebuilds the parent↔child connection tree for a palace that has positions
    // but no reliable connections, by breadth-first walking each floor's
    // adjacency outward from a SINGLE root per connected component (so the
    // hallway chains into one continuous run and rooms attach as entries /
    // outward wings, while sibling rooms stay unconnected). The root is the
    // south end of the hallway, else a stair landing, else the southmost cell.
    func inferringConnections() -> MemoryPalace {
        var byID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        for floor in Set(rooms.map(\.floor)) {
            let floorRooms = rooms.filter { $0.floor == floor }
            let byCell = Dictionary(uniqueKeysWithValues: floorRooms.map { ($0.gridPoint, $0) })

            // Prefer the hallway's south end as the corridor root so the whole
            // hallway chains from one end; fall back to a stair landing, then
            // the southmost cell.
            func pickRoot(_ pool: [PalaceRoom]) -> PalaceRoom? {
                if let hall = pool.filter({ $0.isHallway }).max(by: { $0.y < $1.y }) { return hall }
                if let landing = pool.first(where: { isOccupied($0.x, $0.y, floor: floor - 1) }) { return landing }
                return pool.min(by: { ($0.y, $0.x) < ($1.y, $1.x) })
            }

            // One BFS per connected component so a single root chains its whole
            // component (crucially, all the hallway segments) rather than every
            // hallway cell being its own disconnected root.
            var visited = Set<UUID>()
            while visited.count < floorRooms.count {
                let remaining = floorRooms.filter { !visited.contains($0.id) }
                guard let root = pickRoot(remaining) else { break }
                visited.insert(root.id)
                byID[root.id]?.parentID = nil
                var queue = [root]
                while !queue.isEmpty {
                    let cell = queue.removeFirst()
                    for dir in PalaceDirection.allCases {
                        let point = GridPoint(x: cell.x + dir.delta.dx, y: cell.y + dir.delta.dy)
                        guard let neighbour = byCell[point], !visited.contains(neighbour.id) else { continue }
                        visited.insert(neighbour.id)
                        byID[neighbour.id]?.parentID = cell.id
                        queue.append(byID[neighbour.id]!)
                    }
                }
            }
        }
        var inferred = self
        inferred.rooms = rooms.map { byID[$0.id] ?? $0 }
        return inferred
    }
}

// Lightweight hashable grid key for same-floor adjacency lookups.
private struct GridPoint: Hashable {
    let x: Int
    let y: Int
}

private extension PalaceRoom {
    var gridPoint: GridPoint { GridPoint(x: x, y: y) }
}

// MARK: - Store

// Owns the user's single palace and persists it to UserDefaults, keyed by
// the signed-in uid so switching accounts on one device keeps palaces
// separate. Kept deliberately local for the feature's first cut — no
// Firestore schema yet — but funnelled through one type so a later sync
// backend can slot in behind the same API.
@MainActor
@Observable
final class MemoryPalaceStore {
    static let shared = MemoryPalaceStore()

    private(set) var palace: MemoryPalace

    private let defaults = UserDefaults.standard

    private static func storageKey() -> String {
        let uid = Auth.auth().currentUser?.uid ?? "local"
        return "memoryPalace_\(uid)"
    }

    init() {
        palace = Self.load() ?? .starter()
        migrateIfNeeded()
    }

    // MARK: Persistence

    private static func load() -> MemoryPalace? {
        guard let data = UserDefaults.standard.data(forKey: storageKey()) else { return nil }
        return try? JSONDecoder().decode(MemoryPalace.self, from: data)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(palace) else { return }
        defaults.set(data, forKey: Self.storageKey())
    }

    // Re-reads the palace for the current user. Call when the profile screen
    // appears so an account switch since init is reflected.
    func reload() {
        palace = Self.load() ?? .starter()
        migrateIfNeeded()
    }

    // Upgrades older palaces: those saved before hallways get rebuilt around a
    // corridor; those with a hallway but no recorded connections (saved between
    // the hallway and the connection-tree changes) get their doors inferred.
    // Persisted so each upgrade is one-time.
    private func migrateIfNeeded() {
        if !palace.hasHallway {
            palace = palace.migratedToHallway()
            persist()
        } else if palace.needsConnectionInference {
            palace = palace.inferringConnections()
            persist()
        }
    }

    // MARK: Mutations

    var rooms: [PalaceRoom] { palace.rooms }

    func renamePalace(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        palace.name = trimmed.isEmpty ? "My Memory Palace" : trimmed
        persist()
    }

    // Carves a new cell one step off `room` in `direction` on the same floor,
    // if that cell is free. Extending a hallway ALONG its axis (north/south)
    // grows the corridor; extending a hallway to a SIDE (east/west), or
    // extending any room, creates a room (rooms can chain into deeper wings).
    // Returns the new cell so the caller can select it.
    @discardableResult
    func extend(from room: PalaceRoom, direction: PalaceDirection) -> PalaceRoom? {
        let nx = room.x + direction.delta.dx
        let ny = room.y + direction.delta.dy
        guard !palace.isOccupied(nx, ny, floor: room.floor) else { return nil }

        let alongCorridor = direction == .north || direction == .south
        // Rooms may only grow PERPENDICULAR to the hallway (east/west, outward as
        // wings). Extending a room along the corridor axis would place a room
        // parallel and adjacent to the hallway, which we don't allow. The
        // hallway itself still extends along its axis or spins off side rooms.
        if !room.isHallway && alongCorridor { return nil }
        let newKind: PalaceRoomKind = (room.isHallway && alongCorridor) ? .hallway : .room

        let new: PalaceRoom
        if newKind == .hallway {
            new = PalaceRoom(name: "Hallway", x: nx, y: ny, floor: room.floor, colorIndex: 0, kind: .hallway, parentID: room.id)
        } else {
            // Cycle the palette so the fresh room is visually distinct from its
            // parent without the user having to choose a colour.
            let nextColor = (room.colorIndex + 1) % MemoryPalace.paletteHexes.count
            new = PalaceRoom(
                name: "Room \(nextRoomNumber())",
                x: nx,
                y: ny,
                floor: room.floor,
                colorIndex: nextColor,
                kind: .room,
                parentID: room.id
            )
        }
        palace.rooms.append(new)
        persist()
        return new
    }

    // Next sequential number for a freshly-created room, ignoring hallway
    // segments so room names read "Room 1, 2, 3…" regardless of corridor size.
    private func nextRoomNumber() -> Int {
        palace.rooms.filter { !$0.isHallway }.count + 1
    }

    // Adds a room directly above (or below) `room` on the adjacent floor,
    // linked by stairs, if that spot is free. This is how the palace gains a
    // second/third story: you stack a room on top of an existing one.
    @discardableResult
    func extendVertical(from room: PalaceRoom, up: Bool) -> PalaceRoom? {
        let newFloor = room.floor + (up ? 1 : -1)
        guard !palace.isOccupied(room.x, room.y, floor: newFloor) else { return nil }
        // Stacking preserves the cell's kind so a hallway rises as a hallway
        // (stairs stay within the corridor) and a room rises as a room.
        let new: PalaceRoom
        if room.isHallway {
            new = PalaceRoom(name: "Hallway", x: room.x, y: room.y, floor: newFloor, colorIndex: 0, kind: .hallway)
        } else {
            let nextColor = (room.colorIndex + 1) % MemoryPalace.paletteHexes.count
            new = PalaceRoom(
                name: "Room \(nextRoomNumber())",
                x: room.x,
                y: room.y,
                floor: newFloor,
                colorIndex: nextColor,
                kind: .room
            )
        }
        palace.rooms.append(new)
        persist()
        return new
    }

    func update(_ room: PalaceRoom) {
        guard let index = palace.rooms.firstIndex(where: { $0.id == room.id }) else { return }
        palace.rooms[index] = room
        persist()
    }

    func assignDeck(_ deck: DeckDocument, to roomID: UUID) {
        guard let index = palace.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        palace.rooms[index].deckId = deck.id
        palace.rooms[index].deckTitle = deck.title
        persist()
    }

    func clearDeck(from roomID: UUID) {
        guard let index = palace.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        palace.rooms[index].deckId = nil
        palace.rooms[index].deckTitle = nil
        persist()
    }

    // Removes a room. Hallway segments are structural circulation and can't be
    // deleted here, and the palace never drops below one cell, so the 2D map
    // always has something to render.
    func removeRoom(_ roomID: UUID) {
        guard palace.rooms.count > 1 else { return }
        guard let room = palace.rooms.first(where: { $0.id == roomID }), !room.isHallway else { return }
        palace.rooms.removeAll { $0.id == roomID }
        persist()
    }
}
