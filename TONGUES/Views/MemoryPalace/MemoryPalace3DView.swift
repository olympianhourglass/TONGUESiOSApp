import SwiftUI
import SceneKit
import UIKit
import QuartzCore
import Observation

// First-person walkthrough of the palace. The floor-plan is extruded into a
// single connected structure — abutting floors, shared walls, and real
// doorway gaps between connected rooms — and the user drops in at eye level,
// drags anywhere to look around, and drives the on-screen joystick to walk.
// Walls block movement except through doorways, so it reads as one building
// rather than a scatter of boxes.
struct MemoryPalace3DView: View {
    @Environment(\.dismiss) private var dismiss
    let store: MemoryPalaceStore
    let decks: [DeckDocument]

    @State private var moveVector: CGVector = .zero
    @State private var teleportRoomID: UUID?
    // A requested floor change from the minimap's up/down controls; the rig
    // consumes it and moves the player to that story.
    @State private var floorCommand: Int?
    // Live player location + facing, written by the SceneKit rig and read by
    // the minimap so it tracks the user as they walk and look around.
    @State private var pose = PalacePose()
    // Decks fetched by the walkthrough itself so the wall words never depend on
    // the parent having finished loading before this screen opened.
    @State private var liveDecks: [DeckDocument] = []

    // Prefer freshly-fetched decks; fall back to whatever the parent passed in.
    private var effectiveDecks: [DeckDocument] {
        liveDecks.isEmpty ? decks : liveDecks
    }

    private var decksById: [String: DeckDocument] {
        Dictionary(uniqueKeysWithValues: effectiveDecks.compactMap { deck in
            deck.id.map { ($0, deck) }
        })
    }

    var body: some View {
        ZStack {
            PalaceSceneView(
                rooms: store.rooms,
                openings: openingsByRoom,
                wordsByRoom: wordsByRoom,
                moveVector: $moveVector,
                teleportRoomID: $teleportRoomID,
                floorCommand: $floorCommand,
                pose: pose
            )
            .ignoresSafeArea()

            crosshair

            VStack {
                HStack(alignment: .top) {
                    Spacer(minLength: 8)
                    VStack(spacing: 6) {
                        PalaceMinimap(
                            rooms: store.rooms.filter { $0.floor == pose.floor },
                            pose: pose
                        )
                        if store.palace.floors.count > 1 {
                            floorControls
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 10)
                }
                Spacer()
                HStack {
                    MovementJoystick(vector: $moveVector)
                        .frame(width: 128, height: 128)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(store.palace.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L("Done")) { dismiss() }
                    .tint(.black)
            }
        }
        .task {
            // Self-load decks so the wall words appear regardless of whether the
            // parent had finished fetching before the walkthrough opened.
            if let fetched = try? await FirebaseDeckService.fetchDecks(), !fetched.isEmpty {
                liveDecks = fetched
            }
        }
    }

    private var crosshair: some View {
        Circle()
            .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
            .frame(width: 6, height: 6)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)
    }

    // Up/down story switcher under the minimap. Enabled only toward floors
    // that actually exist; tapping asks the rig to move to that story.
    private var floorControls: some View {
        let floors = store.palace.floors
        let canUp = floors.contains(pose.floor + 1)
        let canDown = floors.contains(pose.floor - 1)
        return HStack(spacing: 10) {
            Button {
                Haptics.light()
                floorCommand = pose.floor - 1
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canDown ? .black : .black.opacity(0.25))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canDown)

            Text(floorShortLabel(pose.floor))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)

            Button {
                Haptics.light()
                floorCommand = pose.floor + 1
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canUp ? .black : .black.opacity(0.25))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canUp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.08)))
    }

    private func floorShortLabel(_ floor: Int) -> String {
        floor >= 0 ? "\(floor + 1)F" : "B\(-floor)"
    }

    private var openingsByRoom: [UUID: Set<PalaceDirection>] {
        Dictionary(uniqueKeysWithValues: store.rooms.map { room in
            (room.id, store.palace.openings(from: room))
        })
    }

    // Every word of each room's assigned deck. The 3D view lays them out in
    // columns across the room's walls, so the full list stays visible.
    private var wordsByRoom: [UUID: [PalaceWord]] {
        var result: [UUID: [PalaceWord]] = [:]
        for room in store.rooms {
            guard let id = room.deckId, let deck = decksById[id] else { continue }
            result[room.id] = deck.items.map {
                PalaceWord(word: $0.word, translation: $0.translation)
            }
        }
        return result
    }
}

// A single memorised word placed in a room's 3D space.
struct PalaceWord: Hashable {
    let word: String
    let translation: String
}

// MARK: - Minimap

// Live player pose shared between the SceneKit rig (writer) and the minimap
// (reader). Grid cell drives which room the player is in; yaw drives the
// facing arrow. Not main-actor-isolated so the display-link tick can write it
// directly; all writes happen on the main thread anyway.
@Observable
final class PalacePose {
    var gx: Int = 0
    var gy: Int = 0
    var floor: Int = 0
    var yaw: Float = 0
}

// Compact top-down map of the palace, mirroring the 2D floor-plan, with the
// player's current room highlighted and a north-referenced arrow showing which
// way they're facing. Updates as the user walks (cell) and looks (yaw).
struct PalaceMinimap: View {
    let rooms: [PalaceRoom]
    let pose: PalacePose

    private let cell: CGFloat = 15
    private let gap: CGFloat = 3

    // A contiguous vertical hallway column, drawn as one merged rectangle.
    private struct HallRun: Identifiable {
        let x: Int
        let minY: Int
        let maxY: Int
        var id: Int { x }
    }

    // Hallway cells grouped into one run per column (min→max y).
    private var hallwayRuns: [HallRun] {
        let byColumn = Dictionary(grouping: rooms.filter { $0.isHallway }, by: \.x)
        return byColumn.map { x, cells in
            HallRun(x: x, minY: cells.map(\.y).min() ?? 0, maxY: cells.map(\.y).max() ?? 0)
        }
    }

    var body: some View {
        let xs = rooms.map(\.x)
        let ys = rooms.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let cols = maxX - minX + 1
        let rowsN = maxY - minY + 1
        let pitch = cell + gap

        ZStack(alignment: .topLeading) {
            // The hallway draws as one continuous runner rectangle per column
            // (rather than a stack of separate cells) so it reads as one long
            // corridor. Rooms branching off it stay individual squares.
            ForEach(hallwayRuns) { run in
                let onRun = pose.gx == run.x && pose.gy >= run.minY && pose.gy <= run.maxY
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.55))
                    .frame(width: cell, height: CGFloat(run.maxY - run.minY) * pitch + cell)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(onRun ? Color.black : Color.black.opacity(0.12),
                                    lineWidth: onRun ? 1.6 : 0.8)
                    )
                    .offset(
                        x: CGFloat(run.x - minX) * pitch,
                        y: CGFloat(run.minY - minY) * pitch
                    )
            }

            ForEach(rooms.filter { !$0.isHallway }) { room in
                let isHere = room.x == pose.gx && room.y == pose.gy
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(uiColor: MemoryPalace.uiColor(forIndex: room.colorIndex)))
                    .frame(width: cell, height: cell)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isHere ? Color.black : Color.black.opacity(0.12),
                                    lineWidth: isHere ? 1.6 : 0.8)
                    )
                    .offset(
                        x: CGFloat(room.x - minX) * pitch,
                        y: CGFloat(room.y - minY) * pitch
                    )
            }

            // Facing arrow at the player's cell. north.fill points up (north);
            // rotating by -yaw aligns it with the walk direction, since yaw = 0
            // faces -z (north / up on the map).
            Image(systemName: "location.north.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .rotationEffect(.radians(Double(-pose.yaw)))
                .frame(width: cell, height: cell)
                .offset(
                    x: CGFloat(pose.gx - minX) * pitch,
                    y: CGFloat(pose.gy - minY) * pitch
                )
        }
        .frame(
            width: CGFloat(cols) * pitch - gap,
            height: CGFloat(rowsN) * pitch - gap,
            alignment: .topLeading
        )
        .padding(9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
    }
}

// MARK: - On-screen movement joystick

// A thumb joystick: drag the knob to emit a normalised vector (dy up =
// forward, dx right = strafe). Snaps back to centre on release.
struct MovementJoystick: View {
    @Binding var vector: CGVector

    @State private var knob: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().fill(Color.black.opacity(0.10))
                Circle().stroke(Color.black.opacity(0.15), lineWidth: 1)
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: radius, height: radius)
                    .offset(knob)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var t = value.translation
                        let dist = hypot(t.width, t.height)
                        if dist > radius, dist > 0 {
                            let scale = radius / dist
                            t.width *= scale
                            t.height *= scale
                        }
                        knob = t
                        // Invert vertical so pushing up walks forward.
                        vector = CGVector(dx: t.width / radius, dy: -t.height / radius)
                    }
                    .onEnded { _ in
                        knob = .zero
                        vector = .zero
                    }
            )
        }
    }
}

// MARK: - SceneKit

// Builds and hosts the connected SceneKit palace and runs the first-person
// rig. Rooms tile on the same integer grid as the 2D map (grid y → world z)
// with `spacing == roomSize`, so floors abut into one continuous plane;
// perimeter edges get solid walls and connected edges get a wall with a
// central doorway gap. A yaw node carries the pitching camera so look and
// walk stay independent, and a display link integrates joystick movement
// with grid-based wall collision.
struct PalaceSceneView: UIViewRepresentable {
    let rooms: [PalaceRoom]
    let openings: [UUID: Set<PalaceDirection>]
    let wordsByRoom: [UUID: [PalaceWord]]
    @Binding var moveVector: CGVector
    @Binding var teleportRoomID: UUID?
    @Binding var floorCommand: Int?
    let pose: PalacePose

    // World-space geometry. spacing == roomSize keeps adjacent floors seamless.
    // Rooms are deliberately roomy so the central staircase takes only a small
    // share of the floor rather than dominating it.
    private let spacing: Float = 9.0
    private let roomSize: Float = 9.0
    private let wallHeight: Float = 3.2
    private let wallThickness: Float = 0.18
    private let doorwayWidth: Float = 2.4
    private let eyeHeight: Float = 1.6
    // Each story is exactly one wall tall, so an upper floor's slab lands right
    // on top of the walls below and doubles as their ceiling.
    private var storyHeight: Float { wallHeight }
    // Footprint of the stairwell hole + staircase within a room, centred. Well
    // under a third of the room's width, so most of the floor stays open.
    private let stairWell: Float = 3.0

    // Muted runner colour for hallway floor slabs so the corridor reads
    // distinctly from the palette-coloured rooms that branch off it.
    private var hallwayFloorColor: UIColor { UIColor(white: 0.62, alpha: 1) }

    // The cell to spawn in: the south end of the hallway on the lowest floor.
    private var spawnCell: PalaceRoom? {
        let lowestFloor = rooms.map(\.floor).min() ?? 0
        let hall = rooms.filter { $0.isHallway && $0.floor == lowestFloor }
        if let entrance = hall.max(by: { $0.y < $1.y }) { return entrance }
        return rooms.min { ($0.floor, $0.y, $0.x) < ($1.floor, $1.y, $1.x) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        // Our own key/fill/ambient rig (see addLighting) shapes the rooms; the
        // automatic default light would flatten that back into an even wash.
        view.autoenablesDefaultLighting = false
        // Warm, dim parchment backdrop instead of clinical white.
        let backdrop = UIColor(red: 0.82, green: 0.76, blue: 0.66, alpha: 1)
        view.backgroundColor = backdrop

        let scene = SCNScene()
        scene.background.contents = backdrop
        buildStructure(into: scene)
        if hasAnyWords {
            buildWordLabels(into: scene)
            context.coordinator.wordsBuilt = true
        }
        addLighting(to: scene)

        // First-person rig: playerNode yaws, camera pitches.
        let player = SCNNode()
        let camera = SCNNode()
        let scnCamera = SCNCamera()
        scnCamera.fieldOfView = 65
        scnCamera.zNear = 0.05
        scnCamera.zFar = 500
        // Filmic realism: HDR tone-mapping, contact shadows via screen-space
        // ambient occlusion (the soft darkening where walls meet floor and in
        // corners), and a gentle bloom so the reflected light strips glow.
        scnCamera.wantsHDR = true
        scnCamera.wantsExposureAdaptation = false
        scnCamera.exposureOffset = -0.3
        scnCamera.bloomThreshold = 0.8
        scnCamera.bloomIntensity = 0.45
        scnCamera.bloomBlurRadius = 10
        // Kept gentle: SceneKit's SSAO samples are noisy, so a lower intensity
        // and a wider, softer radius avoid the speckled/grainy look.
        scnCamera.screenSpaceAmbientOcclusionIntensity = 0.55
        scnCamera.screenSpaceAmbientOcclusionRadius = 1.2
        scnCamera.screenSpaceAmbientOcclusionBias = 0.05
        scnCamera.contrast = 0.08
        scnCamera.saturation = 1.06
        scnCamera.motionBlurIntensity = 0.15
        camera.camera = scnCamera
        player.addChildNode(camera)
        scene.rootNode.addChildNode(player)

        let coord = context.coordinator
        coord.configure(
            rooms: rooms,
            openings: openings,
            spacing: spacing,
            roomSize: roomSize,
            wallMargin: 0.4,
            eyeHeight: eyeHeight,
            storyHeight: storyHeight,
            stairWell: stairWell
        )
        coord.playerNode = player
        coord.cameraNode = camera
        coord.moveVectorProvider = { [self] in self.moveVector }
        coord.pose = pose

        // Drop the user into the hallway entrance (south end of the corridor on
        // the lowest floor), facing north up the hallway. Falls back to the
        // first cell if there's somehow no hallway.
        if let spawn = spawnCell {
            coord.gx = spawn.x
            coord.gy = spawn.y
            coord.floor = spawn.floor
            player.position = SCNVector3(
                Float(spawn.x) * spacing,
                Float(spawn.floor) * storyHeight + eyeHeight,
                Float(spawn.y) * spacing
            )
        }
        coord.syncPose()
        coord.applyOrientation()

        view.scene = scene
        view.pointOfView = camera

        let pan = UIPanGestureRecognizer(target: coord, action: #selector(Coordinator.handleLook(_:)))
        view.addGestureRecognizer(pan)

        coord.startLoop()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coord = context.coordinator
        coord.moveVectorProvider = { [self] in self.moveVector }
        // Decks load asynchronously; the moment their words are available, build
        // the wall labels (once) so they always appear even if the walkthrough
        // was opened before the fetch completed.
        if !coord.wordsBuilt, hasAnyWords, let scene = uiView.scene {
            buildWordLabels(into: scene)
            coord.wordsBuilt = true
        }
        if let id = teleportRoomID,
           id != coord.lastTeleportRoomID,
           let room = rooms.first(where: { $0.id == id }) {
            coord.lastTeleportRoomID = id
            coord.teleport(toCellX: room.x, y: room.y, floor: room.floor)
        }
        if let target = floorCommand, target != coord.lastFloorCommand {
            coord.lastFloorCommand = target
            coord.goToFloor(target)
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopLoop()
    }

    // MARK: Structure building

    private func worldCenter(x: Int, y: Int) -> SCNVector3 {
        SCNVector3(Float(x) * spacing, 0, Float(y) * spacing)
    }

    private func buildStructure(into scene: SCNScene) {
        let byCell = Dictionary(uniqueKeysWithValues: rooms.map {
            (GridKey(x: $0.x, y: $0.y, floor: $0.floor), $0)
        })
        // A stacked cell only carries stairs when BOTH it and its neighbour
        // above/below are rooms — the hallway never has stairs.
        func isRoomCell(_ key: GridKey) -> Bool {
            if let cell = byCell[key] { return !cell.isHallway }
            return false
        }

        for room in rooms {
            let base = worldCenter(x: room.x, y: room.y)
            let yBase = Float(room.floor) * storyHeight
            let roomBelow = !room.isHallway && isRoomCell(GridKey(x: room.x, y: room.y, floor: room.floor - 1))
            let roomAbove = !room.isHallway && isRoomCell(GridKey(x: room.x, y: room.y, floor: room.floor + 1))

            // Floor slab. When a ROOM sits above another room, its slab is that
            // room's ceiling — carve a stairwell hole so the two connect.
            // Hallway segments get a muted runner colour; rooms use their swatch.
            addFloorSlab(
                to: scene,
                at: base,
                yBase: yBase,
                color: room.isHallway ? hallwayFloorColor : MemoryPalace.uiColor(forIndex: room.colorIndex),
                stairwell: roomBelow
            )

            // A staircase rising from this room up to the ceiling hole when a
            // room stacks on top. Consecutive floors switch back (reverse
            // direction) so the climb is continuous instead of stacking flights
            // the same way and landing you against the next flight's wall.
            if roomAbove {
                addStairs(to: scene, at: base, yBase: yBase, risesNorth: stairRisesNorth(onFloor: room.floor))
            }

            // The room title is part of the permanent structure; the deck words
            // are built separately (see buildWordLabels) so they can be added as
            // soon as the asynchronously-loaded decks are available. Hallway
            // segments are unlabelled circulation — no title, no words.
            if !room.isHallway {
                addRoomTitle(to: scene, at: base, yBase: yBase, roomName: room.name)
            }
        }

        // Walls, one per grid edge (per floor). A shared edge is built once
        // (from the east/south side). What goes there depends on the connection:
        //   • two hallway segments   → nothing (one continuous open corridor)
        //   • a connected doorway     → a wall with a central doorway gap
        //   • adjacent but unrelated  → a solid wall (sibling rooms don't open
        //                               into each other)
        //   • no neighbour (perimeter)→ a solid wall
        for room in rooms {
            let base = worldCenter(x: room.x, y: room.y)
            let yBase = Float(room.floor) * storyHeight
            let openSet = openings[room.id] ?? []
            for dir in PalaceDirection.allCases {
                let nx = room.x + dir.delta.dx
                let ny = room.y + dir.delta.dy
                if let neighbour = byCell[GridKey(x: nx, y: ny, floor: room.floor)] {
                    guard dir == .east || dir == .south else { continue }   // build shared edge once
                    if room.isHallway && neighbour.isHallway {
                        continue                                            // open corridor
                    } else if openSet.contains(dir) {
                        addDoorwayWall(to: scene, at: base, yBase: yBase, dir: dir)
                    } else {
                        addSolidWall(to: scene, at: base, yBase: yBase, dir: dir)
                    }
                } else {
                    addSolidWall(to: scene, at: base, yBase: yBase, dir: dir)
                }
            }
        }
    }

    // True once at least one room has words to show. Decks load asynchronously,
    // so this can flip from false to true after the scene is first built.
    private var hasAnyWords: Bool {
        wordsByRoom.values.contains { !$0.isEmpty }
    }

    // Builds the wall word labels for every room that has a deck. Kept separate
    // from buildStructure so it can run again the moment the async-loaded decks
    // arrive — this is what guarantees the words always show even if the
    // walkthrough was opened before the fetch finished. Recomputes each room's
    // solid-wall panels exactly as the structure pass does so words never land
    // over a doorway.
    private func buildWordLabels(into scene: SCNScene) {
        let order: [PalaceDirection] = [.north, .west, .east, .south]
        for room in rooms {
            let words = wordsByRoom[room.id] ?? []
            guard !words.isEmpty else { continue }
            let base = worldCenter(x: room.x, y: room.y)
            let yBase = Float(room.floor) * storyHeight
            // A wall is solid (and word-bearing) unless it's an actual doorway.
            // Perimeter walls AND walls shared with an unrelated neighbour are
            // both solid now, so words fill them and only skip real openings.
            let openSet = openings[room.id] ?? []
            let isSolid: (PalaceDirection) -> Bool = { !openSet.contains($0) }
            let wallOrder = order.filter(isSolid) + order.filter { !isSolid($0) }
            let panels = wallOrder.flatMap { dir in
                wallPanels(base: base, dir: dir, solid: isSolid(dir))
            }
            addWordColumns(to: scene, at: base, yBase: yBase, panels: panels, words: words)
        }
    }

    // Floor slab for a room. `stairwell` true builds the slab as four border
    // panels around a central hole so a staircase from the room below can pass
    // through; otherwise it's a single solid slab.
    private func addFloorSlab(to scene: SCNScene, at base: SCNVector3, yBase: Float, color: UIColor, stairwell: Bool) {
        let material = SCNMaterial()
        material.diffuse.contents = color
        let y = yBase - 0.05

        func slab(width: Float, length: Float, x: Float, z: Float) {
            let box = SCNBox(width: CGFloat(width), height: 0.1, length: CGFloat(length), chamferRadius: 0)
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(x, y, z)
            scene.rootNode.addChildNode(node)
        }

        guard stairwell else {
            slab(width: roomSize, length: roomSize, x: base.x, z: base.z)
            return
        }

        // Four border panels around a centred stairWell × stairWell hole.
        let border = (roomSize - stairWell) / 2
        guard border > 0.01 else {
            slab(width: roomSize, length: roomSize, x: base.x, z: base.z)
            return
        }
        let inner = stairWell
        let off = stairWell / 2 + border / 2
        // North & south strips span the full width.
        slab(width: roomSize, length: border, x: base.x, z: base.z - off)
        slab(width: roomSize, length: border, x: base.x, z: base.z + off)
        // East & west strips fill the remaining middle band.
        slab(width: border, length: inner, x: base.x - off, z: base.z)
        slab(width: border, length: inner, x: base.x + off, z: base.z)
    }

    // A staircase of solid blocks rising from this floor (yBase) up to the
    // ceiling hole (yBase + storyHeight), centred in the room. `risesNorth`
    // flips the run so alternating floors switch back: the flight's foot is at
    // the same edge where the flight below deposited the climber, so ascending
    // is one continuous zig-zag instead of a stack of same-facing flights.
    private func addStairs(to scene: SCNScene, at base: SCNVector3, yBase: Float, risesNorth: Bool) {
        let steps = 10
        let rise = storyHeight / Float(steps)
        let run = stairWell / Float(steps)
        let width = stairWell * 0.72
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.72, alpha: 1)

        for i in 0..<steps {
            // Each step is a solid block from the floor up to its tread, so the
            // run looks like a staircase rather than floating treads.
            let height = rise * Float(i + 1)
            let box = SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(run), chamferRadius: 0)
            box.materials = [material]
            let node = SCNNode(geometry: box)
            let along = run * (Float(i) + 0.5)
            // Shortest step (the foot) at the north edge for a +z flight, or the
            // south edge for a flight that rises toward -z (north).
            let z = risesNorth
                ? base.z + stairWell / 2 - along
                : base.z - stairWell / 2 + along
            node.position = SCNVector3(base.x, yBase + height / 2, z)
            scene.rootNode.addChildNode(node)
        }
    }

    private func wallMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        // Clearly reflective: a smooth, largely-metallic surface mirrors the
        // environment's bright light strips. Metals show reflection over diffuse,
        // so this is what makes the reflection obvious (roughness blurs it a
        // touch so it's a polished sheen, not a hard mirror).
        material.metalness.contents = 0.9
        material.roughness.contents = 0.18
        material.isDoubleSided = true
        return material
    }

    private func addSolidWall(to scene: SCNScene, at base: SCNVector3, yBase: Float, dir: PalaceDirection) {
        let half = roomSize / 2
        let isVertical = (dir == .east || dir == .west)
        let box = SCNBox(
            width: CGFloat(isVertical ? wallThickness : roomSize),
            height: CGFloat(wallHeight),
            length: CGFloat(isVertical ? roomSize : wallThickness),
            chamferRadius: 0
        )
        box.materials = [wallMaterial()]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(
            base.x + Float(dir.delta.dx) * half,
            yBase + wallHeight / 2,
            base.z + Float(dir.delta.dy) * half
        )
        scene.rootNode.addChildNode(node)
    }

    // A wall on a connected edge, split into two panels leaving a central
    // doorway opening the user can walk through.
    private func addDoorwayWall(to scene: SCNScene, at base: SCNVector3, yBase: Float, dir: PalaceDirection) {
        let half = roomSize / 2
        let isVertical = (dir == .east || dir == .west)
        let panelSpan = (roomSize - doorwayWidth) / 2
        guard panelSpan > 0.01 else { return }
        let panelOffset = doorwayWidth / 2 + panelSpan / 2

        for side in [Float(-1), Float(1)] {
            let box = SCNBox(
                width: CGFloat(isVertical ? wallThickness : panelSpan),
                height: CGFloat(wallHeight),
                length: CGFloat(isVertical ? panelSpan : wallThickness),
                chamferRadius: 0
            )
            box.materials = [wallMaterial()]
            let node = SCNNode(geometry: box)
            // Edge centre, then slide each panel along the edge to leave the gap.
            let edgeX = base.x + Float(dir.delta.dx) * half
            let edgeZ = base.z + Float(dir.delta.dy) * half
            node.position = SCNVector3(
                edgeX + (isVertical ? 0 : side * panelOffset),
                yBase + wallHeight / 2,
                edgeZ + (isVertical ? side * panelOffset : 0)
            )
            scene.rootNode.addChildNode(node)
        }
    }

    // A solid rectangular stretch of wall the words can be written on: its
    // top-left interior corner, the unit reading axis along the wall, the yaw
    // that faces text inward, and how wide the usable surface is.
    private struct WallPanel {
        let originX: Float
        let originZ: Float
        let rightX: Float
        let rightZ: Float
        let yaw: Float
        let usableWidth: Float
    }

    // Places the room's words flat on its solid wall panels, left-aligned and
    // laid out in newspaper columns: each column fills top-to-bottom, and when
    // a column reaches the floor the next starts to its right. When a panel's
    // columns are exhausted the layout continues on the next panel, so the
    // whole deck stays on real wall surface — never over a doorway. If the
    // deck is small the rows spread to fill the available height; the room name
    // stays a floating, billboarded label so the room is identifiable anywhere.
    // Floating, billboarded room title (centre of the room, near the ceiling).
    // Always added with the structure — independent of whether a deck has been
    // assigned or loaded yet — so every room is identifiable.
    private func addRoomTitle(to scene: SCNScene, at base: SCNVector3, yBase: Float, roomName: String) {
        let title = makeTextNode(roomName, color: .black, weight: .semibold, scale: 0.33, centered: true)
        title.position = SCNVector3(base.x, yBase + wallHeight * 0.9, base.z)
        title.constraints = [SCNBillboardConstraint()]
        scene.rootNode.addChildNode(title)
    }

    private func addWordColumns(
        to scene: SCNScene,
        at base: SCNVector3,
        yBase: Float,
        panels: [WallPanel],
        words: [PalaceWord]
    ) {
        guard !words.isEmpty, !panels.isEmpty else { return }

        // Metrics scale with the room: the walls are wide and stand back from
        // the viewer, so text and spacing are sized to stay legible from the
        // middle of the room. A line wider than the column WRAPS (never
        // truncated); the wider walls simply give more columns to fill.
        let topY = wallHeight - 0.2
        let bottomY: Float = 0.16
        let lineHeight: Float = 0.27
        let columnWidth: Float = 1.8
        let wordScale: Float = 0.098
        let maxLineWidth = columnWidth - 0.2
        let rowsPerColumn = max(1, Int((topY - bottomY) / lineHeight))

        // Flatten the panels into individual columns (each a top-left anchor +
        // facing) in reading order, so an entry can wrap down a column, words
        // spill to the next column, and then onto the next panel — always on
        // solid wall, never over a doorway.
        var columns: [(x: Float, z: Float, yaw: Float)] = []
        for panel in panels {
            let cols = max(1, Int(panel.usableWidth / columnWidth))
            for c in 0..<cols {
                let offset = Float(c) * columnWidth
                columns.append((
                    x: panel.originX + panel.rightX * offset,
                    z: panel.originZ + panel.rightZ * offset,
                    yaw: panel.yaw
                ))
            }
        }
        guard !columns.isEmpty else { return }

        var colIndex = 0
        var row = 0
        for word in words {
            let entry = "\(word.word)  ·  \(word.translation)"
            let lines = wrapToWidth(entry, maxWidth: maxLineWidth, scale: wordScale)

            // Keep a word's wrapped lines together: if they don't fit in the
            // rows left in the current column (and it has already started),
            // jump to the top of the next column.
            if row > 0 && row + lines.count > rowsPerColumn {
                colIndex += 1
                row = 0
            }
            if colIndex >= columns.count { break }   // out of wall space

            for line in lines {
                if row >= rowsPerColumn {
                    colIndex += 1
                    row = 0
                    if colIndex >= columns.count { break }
                }
                let column = columns[colIndex]
                let node = makeTextNode(
                    line,
                    color: UIColor(white: 0.15, alpha: 1),
                    weight: .regular,
                    scale: wordScale
                )
                node.eulerAngles = SCNVector3(0, column.yaw, 0)
                node.position = SCNVector3(column.x, yBase + topY - Float(row) * lineHeight, column.z)
                scene.rootNode.addChildNode(node)
                row += 1
            }
            if colIndex >= columns.count { break }
        }
    }

    // Greedy word-wrap: splits an entry into as many lines as needed so each
    // line's scaled width fits `maxWidth`, keeping whole words together. A
    // single token too wide for the column is hard-broken by characters so it
    // still fits rather than overrunning. Never returns an empty result.
    private func wrapToWidth(_ string: String, maxWidth: Float, scale: Float) -> [String] {
        let tokens = string.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [string] }

        var lines: [String] = []
        var current = ""
        for token in tokens {
            let trial = current.isEmpty ? token : current + " " + token
            if textWidth(trial, scale: scale) <= maxWidth {
                current = trial
            } else if current.isEmpty {
                // Lone token wider than the column — hard-break it.
                let pieces = hardBreak(token, maxWidth: maxWidth, scale: scale)
                lines.append(contentsOf: pieces.dropLast())
                current = pieces.last ?? ""
            } else {
                lines.append(current)
                if textWidth(token, scale: scale) <= maxWidth {
                    current = token
                } else {
                    let pieces = hardBreak(token, maxWidth: maxWidth, scale: scale)
                    lines.append(contentsOf: pieces.dropLast())
                    current = pieces.last ?? ""
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [string] : lines
    }

    // Breaks a single long token by characters so each piece fits the column.
    private func hardBreak(_ string: String, maxWidth: Float, scale: Float) -> [String] {
        var pieces: [String] = []
        var current = ""
        for ch in string {
            let trial = current + String(ch)
            if current.isEmpty || textWidth(trial, scale: scale) <= maxWidth {
                current = trial
            } else {
                pieces.append(current)
                current = String(ch)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [string] : pieces
    }

    // Scaled world-space width of a string rendered as our wall text, used to
    // decide wrap points. A throwaway SCNText is cheap enough for deck sizes.
    private func textWidth(_ string: String, scale: Float) -> Float {
        if string.isEmpty { return 0 }
        let text = SCNText(string: string, extrusionDepth: 0)
        text.font = UIFont.systemFont(ofSize: 1, weight: .regular)
        text.flatness = 0.2
        let (mn, mx) = SCNNode(geometry: text).boundingBox
        return (mx.x - mn.x) * scale
    }

    // Solid label panels for a wall. A perimeter wall yields one full-width
    // panel; a doorway wall yields the two flanking panels on either side of
    // the opening (so nothing lands over the gap). Each panel's origin is its
    // top-left interior corner (from a viewer inside), nudged just off the
    // surface; the reading axis and inward-facing yaw match the wall side.
    private func wallPanels(base: SCNVector3, dir: PalaceDirection, solid: Bool) -> [WallPanel] {
        let half = roomSize / 2
        let sideInset: Float = 0.12         // margin from each panel edge
        let surface = wallThickness / 2 + 0.03

        let wallX = base.x + Float(dir.delta.dx) * half
        let wallZ = base.z + Float(dir.delta.dy) * half
        let inwardX = -Float(dir.delta.dx)
        let inwardZ = -Float(dir.delta.dy)
        let rightX: Float
        let rightZ: Float
        let yaw: Float
        switch dir {
        case .north: rightX = 1;  rightZ = 0;  yaw = 0
        case .south: rightX = -1; rightZ = 0;  yaw = .pi
        case .east:  rightX = 0;  rightZ = 1;  yaw = -.pi / 2
        case .west:  rightX = 0;  rightZ = -1; yaw = .pi / 2
        }

        // Build a panel spanning [aLo, aHi] along the wall (a=0 is the wall
        // centre; +a runs along the reading axis). The panel's left corner is
        // at a = aLo + sideInset.
        func panel(aLo: Float, aHi: Float) -> WallPanel {
            let startA = aLo + sideInset
            let width = (aHi - aLo) - 2 * sideInset
            return WallPanel(
                originX: wallX + rightX * startA + inwardX * surface,
                originZ: wallZ + rightZ * startA + inwardZ * surface,
                rightX: rightX,
                rightZ: rightZ,
                yaw: yaw,
                usableWidth: max(0, width)
            )
        }

        if solid {
            return [panel(aLo: -half, aHi: half)]
        } else {
            let d = doorwayWidth / 2
            return [panel(aLo: -half, aHi: -d), panel(aLo: d, aHi: half)]
                .filter { $0.usableWidth >= 0.3 }
        }
    }

    // Extruded SCNText scaled to world units. By default it's pivoted to its
    // TOP-LEFT so the node's position is the upper-left corner (the anchor the
    // wall columns stack from); `centered` pivots to the middle instead, for
    // the free-floating room title. Callers wrap long strings before calling,
    // so each node is a single line that already fits its column.
    private func makeTextNode(
        _ string: String,
        color: UIColor,
        weight: UIFont.Weight,
        scale: Float,
        centered: Bool = false
    ) -> SCNNode {
        let text = SCNText(string: string, extrusionDepth: 0.01)
        text.font = UIFont.systemFont(ofSize: 1, weight: weight)
        text.flatness = 0.05
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.isDoubleSided = true
        text.materials = [material]

        let node = SCNNode(geometry: text)
        let (minB, maxB) = node.boundingBox
        if centered {
            node.pivot = SCNMatrix4MakeTranslation(
                (minB.x + maxB.x) / 2,
                (minB.y + maxB.y) / 2,
                (minB.z + maxB.z) / 2
            )
        } else {
            node.pivot = SCNMatrix4MakeTranslation(minB.x, maxB.y, (minB.z + maxB.z) / 2)
        }
        node.scale = SCNVector3(scale, scale, scale)
        return node
    }

    // A 2:1 equirectangular environment map used for the glossy walls'
    // reflections. A plain gradient reflected on a flat wall reads as nothing —
    // reflections only pop when the environment has high-contrast features, so
    // this paints a soft vertical gradient and then several bright vertical
    // "light strips" (like overhead gallery lights / windows). As the camera
    // turns, those bright bars sweep across the walls, which is what actually
    // reads as reflective.
    private func environmentMap() -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            // Base vertical gradient: bright ceiling → mid wall → dark floor.
            let base = [
                UIColor(white: 0.95, alpha: 1).cgColor,
                UIColor(white: 0.55, alpha: 1).cgColor,
                UIColor(white: 0.18, alpha: 1).cgColor
            ] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: base, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Bright vertical light strips across the upper half.
            let strips = 7
            let stripWidth: CGFloat = 26
            for i in 0..<strips {
                let x = (CGFloat(i) + 0.5) / CGFloat(strips) * size.width - stripWidth / 2
                let rect = CGRect(x: x, y: 0, width: stripWidth, height: size.height * 0.62)
                cg.setFillColor(UIColor(white: 1.0, alpha: 1).cgColor)
                cg.fill(rect)
            }
        }
    }

    // A soft three-point rig: a cool ambient fill lifts the shadows, a warm key
    // light from above gives the rooms direction and gentle modelling, and a
    // dim cool back-fill from the opposite side rounds off the far surfaces so
    // nothing reads as flat or stale.
    private func addLighting(to scene: SCNScene) {
        // A high-contrast equirectangular environment so the glossy walls have
        // bright features to reflect that sweep as the camera turns. Kept dim so
        // it lends reflections without over-brightening the room.
        scene.lightingEnvironment.contents = environmentMap()
        scene.lightingEnvironment.intensity = 0.7

        // Warm, low-key gallery lighting: a soft amber ambient with a warm key
        // and a gentle warm fill — dimmer overall so the space feels lit, not
        // floodlit.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 230
        ambient.light?.color = UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 620
        sun.light?.color = UIColor(red: 1.0, green: 0.90, blue: 0.76, alpha: 1)
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        // Soft, warm-tinted cast shadows to ground everything in the space.
        // Forward mode with a high-resolution map and many PCF samples keeps the
        // penumbra smooth instead of the grainy speckle deferred mode produced.
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .forward
        sun.light?.shadowColor = UIColor(red: 0.10, green: 0.07, blue: 0.05, alpha: 0.55)
        sun.light?.shadowRadius = 4
        sun.light?.shadowSampleCount = 64
        sun.light?.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light?.automaticallyAdjustsShadowProjection = true
        sun.light?.maximumShadowDistance = 90
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 150
        fill.light?.color = UIColor(red: 1.0, green: 0.94, blue: 0.85, alpha: 1)
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 2.4, 0)
        scene.rootNode.addChildNode(fill)
    }

    // MARK: Coordinator (first-person rig)

    final class Coordinator: NSObject {
        weak var playerNode: SCNNode?
        weak var cameraNode: SCNNode?
        var moveVectorProvider: () -> CGVector = { .zero }
        // Shared pose the minimap reads. Updated on cell changes and looks.
        var pose: PalacePose?

        // Grid + geometry snapshot used for collision.
        private var occupied: Set<GridKey> = []
        private var openings: [GridKey: Set<PalaceDirection>] = [:]
        private var spacing: Float = 6
        private var half: Float = 3
        private var margin: Float = 0.4
        private var eyeHeight: Float = 1.6
        private var storyHeight: Float = 3.2
        private var stairWell: Float = 2.4
        // Cells that have a room directly above / below — the stair links. A
        // list of all rooms lets floor-switching find the nearest room.
        private var stairUp: Set<GridKey> = []
        private var stairDown: Set<GridKey> = []
        private var roomsList: [(x: Int, y: Int, floor: Int)] = []

        // Current occupied cell, floor, orientation, and movement.
        var gx: Int = 0
        var gy: Int = 0
        var floor: Int = 0
        private var yaw: Float = 0
        private var pitch: Float = 0
        private let moveSpeed: Float = 5.4
        // Which way the player is currently traversing a stairwell: +1 climbing
        // to the floor above, -1 descending to the one below, 0 not on stairs.
        // Latched on entry so stacked floors don't flip-flop mid-crossing.
        private var stairDir = 0

        // Walking feel. Input is eased into a velocity so starts/stops carry a
        // little momentum instead of snapping, and a head-bob rocks the camera
        // up/down and side to side in step with distance travelled — with a soft
        // haptic on each footfall — so it reads as walking, not gliding.
        private var velX: Float = 0            // smoothed world-space velocity
        private var velZ: Float = 0
        private var stepPhase: Float = 0       // accumulated footsteps (1.0 = one step)
        private var lastFootstep = 0           // last whole-step index a haptic fired on
        private var bobX: Float = 0            // applied camera-local sway / bounce
        private var bobY: Float = 0
        private let stepLength: Float = 1.5    // distance covered per footstep
        private let bobAmplitudeY: Float = 0.06
        private let bobAmplitudeX: Float = 0.035

        var lastTeleportRoomID: UUID?
        var lastFloorCommand: Int?
        // Guards the one-time build of the wall word labels once decks load.
        var wordsBuilt = false

        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval = 0

        func configure(
            rooms: [PalaceRoom],
            openings: [UUID: Set<PalaceDirection>],
            spacing: Float,
            roomSize: Float,
            wallMargin: Float,
            eyeHeight: Float,
            storyHeight: Float,
            stairWell: Float
        ) {
            self.spacing = spacing
            self.half = roomSize / 2
            self.margin = wallMargin
            self.eyeHeight = eyeHeight
            self.storyHeight = storyHeight
            self.stairWell = stairWell
            occupied = Set(rooms.map { GridKey(x: $0.x, y: $0.y, floor: $0.floor) })
            roomsList = rooms.map { ($0.x, $0.y, $0.floor) }
            var byCell: [GridKey: Set<PalaceDirection>] = [:]
            for room in rooms {
                byCell[GridKey(x: room.x, y: room.y, floor: room.floor)] = openings[room.id] ?? []
            }
            self.openings = byCell
            // Stairs live only between stacked ROOMS — never the hallway — so
            // the corridor stays flat and the second floor is reached through a
            // room. Vertical links are computed over room cells alone.
            let roomCells = Set(rooms.filter { !$0.isHallway }.map { GridKey(x: $0.x, y: $0.y, floor: $0.floor) })
            stairUp = Set(roomCells.filter { roomCells.contains(GridKey(x: $0.x, y: $0.y, floor: $0.floor + 1)) })
            stairDown = Set(roomCells.filter { roomCells.contains(GridKey(x: $0.x, y: $0.y, floor: $0.floor - 1)) })
        }

        // MARK: Look

        @objc func handleLook(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            let sensitivity: Float = 0.005
            yaw -= Float(translation.x) * sensitivity
            pitch -= Float(translation.y) * sensitivity
            let limit = Float.pi / 2 - 0.05
            pitch = min(max(pitch, -limit), limit)
            applyOrientation()
            pose?.yaw = yaw
        }

        func applyOrientation() {
            playerNode?.eulerAngles.y = yaw
            cameraNode?.eulerAngles.x = pitch
        }

        // Pushes the current cell + floor + facing into the shared pose.
        func syncPose() {
            pose?.gx = gx
            pose?.gy = gy
            pose?.floor = floor
            pose?.yaw = yaw
        }

        private func baseY() -> Float { Float(floor) * storyHeight }

        // MARK: Teleport

        func teleport(toCellX x: Int, y: Int, floor targetFloor: Int) {
            gx = x
            gy = y
            floor = targetFloor
            stairDir = 0   // land flat; don't inherit a stair crossing
            velX = 0       // arrive stationary rather than coasting off
            velZ = 0
            playerNode?.position = SCNVector3(Float(x) * spacing, baseY() + eyeHeight, Float(y) * spacing)
            syncPose()
        }

        // Moves to the room on `targetFloor` nearest the current (gx, gy) —
        // preferring the same column so stairs feel continuous.
        func goToFloor(_ targetFloor: Int) {
            let candidates = roomsList.filter { $0.floor == targetFloor }
            guard !candidates.isEmpty else { return }
            let best = candidates.min { a, b in
                let da = abs(a.x - gx) + abs(a.y - gy)
                let db = abs(b.x - gx) + abs(b.y - gy)
                return da < db
            }!
            teleport(toCellX: best.x, y: best.y, floor: targetFloor)
        }

        // MARK: Movement loop

        func startLoop() {
            stopLoop()
            lastTick = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopLoop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            guard let player = playerNode else { return }
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastTick, 1.0 / 30))
            lastTick = now

            let input = moveVectorProvider()
            // Ease the joystick input into a velocity so movement accelerates
            // and coasts to a stop instead of snapping on and off.
            let targetVX = Float(input.dx) * moveSpeed
            let targetVZ = Float(input.dy) * moveSpeed
            let accel = min(1, dt * 9)
            velX += (targetVX - velX) * accel
            velZ += (targetVZ - velZ) * accel

            var pos = player.position
            let prevGx = gx
            let prevGy = gy
            let prevFloor = floor

            let speed = hypotf(velX, velZ)
            if speed > 0.01 {
                // Forward/right derived from yaw (SceneKit looks down -Z).
                let forward = SCNVector3(-sinf(yaw), 0, -cosf(yaw))
                let right = SCNVector3(cosf(yaw), 0, -sinf(yaw))
                let worldDX = right.x * velX + forward.x * velZ
                let worldDZ = right.z * velX + forward.z * velZ

                // Resolve one axis at a time against walls so sliding along a
                // wall stays smooth instead of sticking.
                let beforeX = pos.x
                let beforeZ = pos.z
                pos.x = resolveX(from: pos.x, delta: worldDX * dt)
                pos.z = resolveZ(from: pos.z, delta: worldDZ * dt)
                // Advance the walk cadence by how far we ACTUALLY moved (a wall
                // may have blocked us) so the bob and footsteps track progress.
                advanceWalkCycle(distance: hypotf(pos.x - beforeX, pos.z - beforeZ))
            }

            // Vertical: staircases are continuous ramps (see updateStairs),
            // returning the eye height for the current position; ease toward it
            // so flat ground stays glued and any small mismatch resolves fast.
            let targetY = updateStairs(pos: &pos)
            pos.y += (targetY - pos.y) * min(1, dt * 12)
            player.position = pos

            // Rock the camera with a walking head-bob (settles to rest when
            // still) so the walkthrough feels grounded rather than floating.
            updateHeadBob(moving: speed > 0.2, dt: dt)

            // Only touch the observable pose when the room or floor changes, so
            // the minimap isn't invalidated every frame while walking.
            if gx != prevGx || gy != prevGy || floor != prevFloor {
                pose?.gx = gx
                pose?.gy = gy
                pose?.floor = floor
            }
        }

        // Advances the footstep cadence by the distance walked this tick and
        // fires a soft haptic each time a whole step lands, its strength scaled
        // to how briskly the player is moving.
        private func advanceWalkCycle(distance: Float) {
            guard distance > 0 else { return }
            stepPhase += distance / stepLength
            let idx = Int(stepPhase)
            if idx != lastFootstep {
                lastFootstep = idx
                let speedFrac = min(1, hypotf(velX, velZ) / moveSpeed)
                Haptics.footstep(intensity: CGFloat(0.28 + 0.4 * speedFrac))
            }
        }

        // Camera head-bob: the eye dips on every footfall (twice per stride) and
        // sways gently left/right once per stride, applied as a camera-local
        // offset so the collision body itself never moves. Eases to rest when
        // the player stops so it settles smoothly instead of freezing mid-step.
        private func updateHeadBob(moving: Bool, dt: Float) {
            var targetX: Float = 0
            var targetY: Float = 0
            if moving {
                targetY = -bobAmplitudeY * cosf(2 * .pi * stepPhase)
                targetX = bobAmplitudeX * sinf(.pi * stepPhase)
            }
            let k = min(1, dt * 10)
            bobX += (targetX - bobX) * k
            bobY += (targetY - bobY) * k
            cameraNode?.position = SCNVector3(bobX, bobY, 0)
        }

        // Stair traversal as a continuous ramp. Staircases rise toward +z, so
        // walking south across a room's central stairwell smoothly climbs to the
        // floor above and walking north descends to the one below — the eye
        // height tracks progress across the well rather than snapping. A
        // direction is latched on entry so a room with floors both above and
        // below doesn't flip-flop mid-crossing, and the floor index commits at
        // the landing (nudging the player clear of the well so it can't
        // immediately re-trigger). Returns the eye height for `pos`.
        private func updateStairs(pos: inout SCNVector3) -> Float {
            let cx = Float(gx) * spacing
            let cz = Float(gy) * spacing
            let inWell = max(abs(pos.x - cx), abs(pos.z - cz)) < stairWell / 2
            guard inWell else {
                stairDir = 0
                return baseY() + eyeHeight
            }

            let cell = GridKey(x: gx, y: gy, floor: floor)
            let hasUp = stairUp.contains(cell)
            let hasDown = stairDown.contains(cell)
            // Progress along the stair axis: 0 at the north edge, 1 at the south.
            let t = min(max((pos.z - cz + stairWell / 2) / stairWell, 0), 1)

            // This floor's up-flight and the floor-below's down-flight switch
            // back, so their run direction alternates by floor parity.
            let upNorth = stairRisesNorth(onFloor: floor)
            let downNorth = stairRisesNorth(onFloor: floor - 1)
            // Climb progress: 0 at the flight's foot, 1 at its head.
            let u = upNorth ? (1 - t) : t
            // Descend progress on the flight below: 0 at its head (this floor),
            // 1 at its foot (the floor beneath). The head sits at whichever edge
            // that flight is tallest.
            let downHeadT: Float = downNorth ? 0 : 1
            let d = abs(t - downHeadT)

            // Latch a travel direction on entry. Climbing is prioritised — its
            // foot and the down-flight's head share the switchback landing, and
            // a continuous ascent is the whole point — so a middle floor climbs;
            // descend with the minimap's floor control. Guard the `< 0.5` cases
            // so entering at the far end can't instantly commit a floor change.
            if stairDir == 0 {
                if hasUp, u < 0.5 { stairDir = 1 }
                else if hasDown, d < 0.5 { stairDir = -1 }
                else if hasUp { stairDir = 1 }
                else if hasDown { stairDir = -1 }
            }

            if stairDir == 1, hasUp {
                if u >= 0.98 {                          // reached the upper landing
                    floor += 1
                    // Step clear of the well at the head edge — which is the foot
                    // of the next (reversed) flight, so the climb continues.
                    pos.z = upNorth ? (cz - stairWell / 2 - 0.05)
                                    : (cz + stairWell / 2 + 0.05)
                    stairDir = 0
                    Haptics.footstep(intensity: 0.6)    // stepping onto the landing
                    return baseY() + eyeHeight
                }
                return baseY() + eyeHeight + u * storyHeight
            }
            if stairDir == -1, hasDown {
                if d >= 0.98 {                          // reached the lower landing
                    floor -= 1
                    pos.z = downNorth ? (cz + stairWell / 2 + 0.05)
                                      : (cz - stairWell / 2 - 0.05)
                    stairDir = 0
                    Haptics.footstep(intensity: 0.6)    // stepping onto the landing
                    return baseY() + eyeHeight
                }
                return baseY() + eyeHeight - d * storyHeight
            }
            return baseY() + eyeHeight
        }

        // MARK: Grid collision

        private func opening(_ cell: GridKey, _ dir: PalaceDirection) -> Bool {
            (openings[cell] ?? []).contains(dir)
        }

        private func resolveX(from x: Float, delta: Float) -> Float {
            var newX = x + delta
            let cell = GridKey(x: gx, y: gy, floor: floor)
            let localMax = Float(gx) * spacing + half
            let localMin = Float(gx) * spacing - half
            if newX > localMax {
                if delta > 0, opening(cell, .east) { gx += 1 }
                else { newX = localMax - margin }
            } else if newX < localMin {
                if delta < 0, opening(cell, .west) { gx -= 1 }
                else { newX = localMin + margin }
            }
            return newX
        }

        private func resolveZ(from z: Float, delta: Float) -> Float {
            var newZ = z + delta
            let cell = GridKey(x: gx, y: gy, floor: floor)
            let localMax = Float(gy) * spacing + half
            let localMin = Float(gy) * spacing - half
            if newZ > localMax {
                if delta > 0, opening(cell, .south) { gy += 1 }
                else { newZ = localMax - margin }
            } else if newZ < localMin {
                if delta < 0, opening(cell, .north) { gy -= 1 }
                else { newZ = localMin + margin }
            }
            return newZ
        }
    }
}

// Grid coordinate key for occupancy / opening lookups, scoped to a floor.
private struct GridKey: Hashable {
    let x: Int
    let y: Int
    let floor: Int
}

// Whether a floor's staircase rises toward -z (north) rather than +z (south).
// Alternating by floor parity makes consecutive flights switch back, so the
// geometry builder and the traversal ramp must agree on the same rule.
private func stairRisesNorth(onFloor floor: Int) -> Bool {
    ((floor % 2) + 2) % 2 == 1
}
