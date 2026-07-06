import SwiftUI
import ARKit
import SceneKit
import CoreImage
import UIKit
import simd

// AR scanning components for CameraPage's "AR" capture mode. (This file
// previously hosted a standalone AR page; the surface now lives inside
// CameraPage as a third mode so the AVCapture and AR sessions are
// coordinated by one owner instead of fighting over the camera.)
//
// The learner sweeps their environment; Scan sends the current frame to
// the vision model, which returns every distinct object it can see.
// Each object gets a label pinned to a real-world anchor — target
// language on top, native (English) beneath — that sticks to the object
// as the camera moves.
//
// Rendering note: we render the session through SceneKit's ARSCNView,
// NOT RealityKit's ARView. RealityKit's ARView refused to show the
// camera passthrough in this embedded/handoff context — with
// automaticallyConfigureSession off the feed rendered black, and with it
// on the session stopped delivering frames entirely. ARSCNView draws the
// passthrough reliably while letting us run the ARSession manually, which
// is the mode that consistently delivers frames.

// MARK: - Label model

struct ARWordLabel: Identifiable {
    let id: UUID                 // == the ARAnchor's identifier
    let item: GeneratedItem
    let english: String
    // Where the object actually is on screen (the leader-line target).
    var anchorPoint: CGPoint?    // nil while off-screen / behind camera
    // Where the bubble is drawn — anchorPoint nudged apart from other
    // bubbles so labels don't overlap. Leader line connects the two.
    var screenPoint: CGPoint?
    var isCollected: Bool = true
}

// MARK: - AR session manager

@Observable
@MainActor
final class ARSceneManager {
    enum SupportState { case checking, supported, unsupported, denied }

    // One stable ARSCNView owns the AR camera for the page's lifetime.
    @ObservationIgnored let sceneView = ARSCNView(frame: .zero)
    var supportState: SupportState = .checking
    var labels: [ARWordLabel] = []
    var isScanning = false
    var errorText: String?
    // Transient hint under the reticle ("No objects found — try again").
    var hintText: String?

    // Anchors we placed, kept so Clear can remove them from the session.
    @ObservationIgnored private var placedAnchors: [UUID: ARAnchor] = [:]
    @ObservationIgnored private var frameTick = 0
    @ObservationIgnored private var isRunning = false

    // Auto-scan: labels appear as the user points around, no button
    // press required. A background loop fires a scan whenever the camera
    // has moved to a meaningfully new vantage since the last one, so a
    // static scene doesn't burn repeated vision calls.
    @ObservationIgnored private var autoScanTask: Task<Void, Never>?
    @ObservationIgnored private var lastScanPosition: SIMD3<Float>?
    @ObservationIgnored private var lastScanForward: SIMD3<Float>?
    @ObservationIgnored private var lastScanAt: Date?
    // Target language for the auto-scan loop (the loop has no view to
    // read bindings from). Kept in sync by the view via `updateLocale`.
    @ObservationIgnored private var scanLanguage = ""
    @ObservationIgnored private var scanDialect = ""
    // Tuning: how far / how much rotation counts as a new vantage, and the
    // floor between scans. Deliberately conservative so labels placed for
    // an area stay put instead of the screen constantly re-scanning and
    // piling on new bubbles.
    private let vantageMoveMeters: Float = 0.6
    private let vantageTurnDot: Float = 0.8   // ~37° of camera rotation
    private let minScanGap: TimeInterval = 4.0
    // Once this many labels are pinned, auto-scan stops adding more so the
    // scene doesn't overcrowd. Clearing (trash) resets the count.
    private let maxLabels = 12

    var collectedItems: [GeneratedItem] {
        labels.filter { $0.isCollected }.map { $0.item }
    }

    init() {
        // ARSCNView renders the camera feed as its background by default
        // once the session runs a world-tracking configuration; we just
        // let it manage lighting to match the scene.
        sceneView.automaticallyUpdatesLighting = true
    }

    // MARK: Lifecycle

    /// Keeps the target language/dialect the auto-scan loop uses current.
    /// Called by the view on start and whenever the pickers change.
    func updateLocale(language: String, dialect: String) {
        scanLanguage = language
        scanDialect = dialect
    }

    /// Starts (or resumes) the AR session. Idempotent — safe to call on
    /// every switch into AR mode. The caller is responsible for stopping
    /// any AVCaptureSession first; only one of the two can own the
    /// camera at a time.
    func start(language: String, dialect: String) async {
        updateLocale(language: language, dialect: dialect)
        guard ARWorldTrackingConfiguration.isSupported else {
            supportState = .unsupported
            return
        }
        // Resolve the camera permission up front so a denial shows the
        // same guidance panel the other capture modes use.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied, .restricted:
            supportState = .denied
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                supportState = .denied
                return
            }
        default:
            break
        }
        guard !isRunning else {
            supportState = .supported
            return
        }

        // Fresh session each time we enter AR: reset tracking and drop
        // any stale anchors so the camera feed always comes back clean
        // after an AVCapture → AR handoff. Label bookkeeping is reset to
        // match, since their anchors are being removed.
        placedAnchors.removeAll()
        labels.removeAll()
        lastScanPosition = nil
        lastScanForward = nil
        lastScanAt = nil

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        // On LiDAR devices, per-pixel depth lets us pin each label at the
        // object's true distance instead of guessing off a plane — the
        // arrows then land on the right object. No-op on non-LiDAR devices.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        isRunning = true
        supportState = .supported
        startAutoScan()
    }

    func pause() {
        guard isRunning else { return }
        autoScanTask?.cancel()
        autoScanTask = nil
        sceneView.session.pause()
        isRunning = false
    }

    // MARK: Auto-scan loop

    // Polls once a second; each tick decides whether the camera has
    // reached a new vantage worth labeling. Motion-gating keeps a still
    // scene from firing repeated vision calls while still labeling
    // automatically as the user explores — no button press needed.
    private func startAutoScan() {
        autoScanTask?.cancel()
        autoScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.autoScanTick()
            }
        }
    }

    private func autoScanTick() async {
        guard isRunning, supportState == .supported, !isScanning,
              !scanLanguage.isEmpty, labels.count < maxLabels else { return }
        let now = Date()
        if let last = lastScanAt, now.timeIntervalSince(last) < minScanGap { return }

        guard let cameraTransform = sceneView.session.currentFrame?.camera.transform else { return }
        let position = Self.translation(of: cameraTransform)
        let forward = Self.forward(of: cameraTransform)

        // First scan of the session always fires; afterwards only when
        // the user has physically moved or turned to a new view.
        let isNewVantage: Bool = {
            guard let lastPosition = lastScanPosition,
                  let lastForward = lastScanForward else { return true }
            let moved = simd_distance(lastPosition, position) > vantageMoveMeters
            let turned = simd_dot(simd_normalize(forward), simd_normalize(lastForward)) < vantageTurnDot
            return moved || turned
        }()
        guard isNewVantage else { return }

        await scan(language: scanLanguage, dialect: scanDialect, isAuto: true)
    }

    func clearLabels() {
        for (_, anchor) in placedAnchors {
            sceneView.session.remove(anchor: anchor)
        }
        placedAnchors.removeAll()
        labels.removeAll()
        hintText = nil
    }

    func toggleCollected(_ id: UUID) {
        guard let index = labels.firstIndex(where: { $0.id == id }) else { return }
        labels[index].isCollected.toggle()
    }

    // MARK: Projection loop

    // Fired by ARSCNView's render delegate each rendered frame (hopped to
    // the main actor). Throttled to halve SwiftUI churn.
    func onSceneUpdate() {
        frameTick += 1
        guard frameTick % 2 == 0, !labels.isEmpty else { return }
        updateProjections()
    }

    // Approximate bubble footprint used for overlap tests, and how far a
    // bubble floats above its object by default. Generous spacing so many
    // labels spread out into free screen space instead of clustering.
    private let labelSize = CGSize(width: 170, height: 54)
    private let labelLift: CGFloat = 30

    // Projects each anchor's world position onto the viewport using the
    // current camera, so bubbles track their objects as the phone moves.
    // We use ARCamera.projectPoint (frame-based, thread-safe) plus an
    // explicit behind-camera cull, rather than the view's point of view.
    private func updateProjections() {
        guard let frame = sceneView.session.currentFrame else { return }
        let viewSize = sceneView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let cameraInverse = simd_inverse(frame.camera.transform)

        // First pass: project each visible anchor to the object's on-screen
        // point (the leader-line target) and seed a bubble position just
        // above it.
        struct Placement {
            let index: Int
            let anchor: CGPoint   // the object on screen
            var pos: CGPoint      // the bubble (gets nudged apart)
        }
        var placements: [Placement] = []
        for index in labels.indices {
            guard let anchor = placedAnchors[labels[index].id] else {
                labels[index].anchorPoint = nil
                labels[index].screenPoint = nil
                continue
            }
            let column = anchor.transform.columns.3
            let world = SIMD3<Float>(column.x, column.y, column.z)

            // Cull points behind the camera: in camera space, forward is
            // -Z, so anything with z >= 0 is behind the lens.
            let local = cameraInverse * SIMD4<Float>(world, 1)
            guard local.z < 0 else {
                labels[index].anchorPoint = nil
                labels[index].screenPoint = nil
                continue
            }

            let projected = frame.camera.projectPoint(
                world,
                orientation: .portrait,
                viewportSize: viewSize
            )
            // Drop points projected outside a generous margin so labels
            // don't smear along the edges when the object leaves frame.
            guard projected.x > -60, projected.x < viewSize.width + 60,
                  projected.y > -40, projected.y < viewSize.height + 40 else {
                labels[index].anchorPoint = nil
                labels[index].screenPoint = nil
                continue
            }
            let object = CGPoint(x: projected.x, y: projected.y)
            // Seed the bubble above the object, with a tiny per-index
            // offset so exactly-overlapping anchors have a direction to
            // separate along (avoids a degenerate all-same-point case).
            let seed = CGPoint(
                x: object.x + CGFloat((index % 3) - 1) * 2,
                y: max(28, object.y - labelLift)
            )
            placements.append(Placement(index: index, anchor: object, pos: seed))
        }

        // Force-directed de-clutter: repeatedly push overlapping bubbles
        // apart along their smaller-overlap axis (so some spread sideways,
        // some up/down — never a single column), with a weak spring pulling
        // each back toward its object so labels stay close to what they
        // name. The leader line drawn in the view keeps the association
        // clear even after a nudge.
        let minGapX = labelSize.width
        let minGapY = labelSize.height
        for _ in 0..<20 {
            for a in placements.indices {
                for b in (a + 1)..<placements.count {
                    let dx = placements[b].pos.x - placements[a].pos.x
                    let dy = placements[b].pos.y - placements[a].pos.y
                    let overlapX = minGapX - abs(dx)
                    let overlapY = minGapY - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    if overlapX * minGapY < overlapY * minGapX {
                        // Separate horizontally — the shallower overlap.
                        let shift = (overlapX / 2) * (dx < 0 ? -1 : 1)
                        placements[a].pos.x -= shift
                        placements[b].pos.x += shift
                    } else {
                        let shift = (overlapY / 2) * (dy < 0 ? -1 : 1)
                        placements[a].pos.y -= shift
                        placements[b].pos.y += shift
                    }
                }
            }
            // Weak spring back toward each object's lifted anchor.
            for i in placements.indices {
                let target = CGPoint(x: placements[i].anchor.x,
                                     y: max(28, placements[i].anchor.y - labelLift))
                placements[i].pos.x += (target.x - placements[i].pos.x) * 0.055
                placements[i].pos.y += (target.y - placements[i].pos.y) * 0.055
            }
        }
        // Keep bubbles on screen.
        for i in placements.indices {
            placements[i].pos.x = min(max(placements[i].pos.x, 20), viewSize.width - 20)
            placements[i].pos.y = min(max(placements[i].pos.y, 24), viewSize.height - 20)
        }

        for placement in placements {
            labels[placement.index].anchorPoint = placement.anchor
            labels[placement.index].screenPoint = placement.pos
        }
    }

    // MARK: Scan

    // `isAuto` scans come from the motion-gated background loop: they
    // record the vantage for the next gate and stay quiet on empty /
    // failed results (no hint flashes, no error alert) so the automatic
    // labeling never nags. Manual scans (the button) surface both.
    func scan(language: String, dialect: String, isAuto: Bool = false) async {
        guard !isScanning, supportState == .supported else { return }
        isScanning = true
        if !isAuto { hintText = nil }
        // Record this attempt's vantage up front so the auto-gate always
        // advances, even if the scan finds nothing — otherwise a barren
        // view would retrigger every second.
        lastScanAt = Date()
        if let cameraTransform = sceneView.session.currentFrame?.camera.transform {
            lastScanPosition = Self.translation(of: cameraTransform)
            lastScanForward = Self.forward(of: cameraTransform)
        }
        defer { isScanning = false }

        // The session needs a beat after run() before frames flow —
        // especially right after an AVCapture → AR handoff. Poll briefly
        // instead of failing on the first nil.
        var currentFrame = sceneView.session.currentFrame
        if currentFrame == nil {
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(250))
                if let frame = sceneView.session.currentFrame {
                    currentFrame = frame
                    break
                }
            }
        }
        guard let frame = currentFrame else {
            if !isAuto { errorText = "The camera is still warming up. Try again in a second." }
            return
        }

        let viewSize = sceneView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0,
              let jpeg = Self.scanJPEG(frame: frame, viewSize: viewSize) else {
            if !isAuto { errorText = "Couldn't read the camera frame. Try again." }
            return
        }

        do {
            let objects = try await DeckGenerator.identifyObjectsInScene(
                imageData: jpeg,
                language: language,
                dialect: dialect
            )
            guard !objects.isEmpty else {
                if !isAuto {
                    Haptics.light()
                    hintText = "No objects recognized — get closer and rescan."
                }
                return
            }
            var added = 0
            for object in objects {
                // Skip words already pinned from a previous scan.
                guard !labels.contains(where: { $0.item.word == object.word }) else { continue }
                let point = CGPoint(
                    x: object.x * viewSize.width,
                    y: object.y * viewSize.height
                )
                guard let transform = worldTransform(for: point) else { continue }
                let anchor = ARAnchor(transform: transform)
                sceneView.session.add(anchor: anchor)
                placedAnchors[anchor.identifier] = anchor
                let item = GeneratedItem(
                    word: object.word,
                    translation: object.english,
                    transliteration: object.transliteration,
                    language: language,
                    partsOfSpeech: ["Noun"],
                    addedAt: Date()
                )
                labels.append(ARWordLabel(
                    id: anchor.identifier,
                    item: item,
                    english: object.english,
                    screenPoint: point
                ))
                added += 1
            }
            if added > 0 {
                Haptics.success()
                hintText = nil
            } else if !isAuto {
                hintText = "Nothing new — everything here is already labeled."
            }
        } catch {
            // Auto scans fail silently (a transient network blip shouldn't
            // interrupt exploring); the manual button reports the error.
            if !isAuto {
                Haptics.error()
                errorText = error.localizedDescription
            }
        }
    }

    // Real-world transform for a screen point. Everything is anchored along
    // the ray that passes through THAT point (not the camera center — using
    // the camera-forward ray was pinning every fallback anchor to whatever
    // sat in the middle of the frame, which is why arrows pointed at the
    // wrong object). We take a real surface hit when it's at a plausible
    // distance, and otherwise pin ~1m out along the point's own ray.
    private func worldTransform(for point: CGPoint) -> simd_float4x4? {
        guard let query = sceneView.raycastQuery(
            from: point,
            allowing: .estimatedPlane,
            alignment: .any
        ) else { return nil }

        // Best source: LiDAR depth sampled at the exact scan point, placed
        // along that point's ray. This pins the label on the actual object
        // surface rather than a plane that may sit behind it.
        if let distance = sampledDepthAlongRay(at: point, ray: query) {
            let position = query.origin + simd_normalize(query.direction) * distance
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
            return transform
        }

        // Accept a plane hit only when it's within arm/room reach; a far hit
        // is usually the wall behind the object and would mis-place the pin.
        if let hit = sceneView.session.raycast(query).first {
            let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                      hit.worldTransform.columns.3.y,
                                      hit.worldTransform.columns.3.z)
            if simd_distance(hitPos, query.origin) <= 2.5 {
                return hit.worldTransform
            }
        }

        // Fallback: a fixed distance along the point's own ray, so the pin
        // stays in the object's direction on featureless scenes.
        let position = query.origin + simd_normalize(query.direction) * 1.0
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }

    // Distance from the camera to the surface under `point`, measured
    // along that point's ray, using the LiDAR depth map. Returns nil when
    // depth isn't available (non-LiDAR device) or the reading is
    // implausible, so the caller falls back to plane/ray placement.
    private func sampledDepthAlongRay(at point: CGPoint, ray: ARRaycastQuery) -> Float? {
        guard let frame = sceneView.session.currentFrame,
              let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let viewSize = sceneView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }

        // View point → normalized image coordinates (the depth map's space).
        let viewNormalized = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
        let imageNormalized = viewNormalized.applying(toImage)
        let px = Int((imageNormalized.x * CGFloat(width)).rounded())
        let py = Int((imageNormalized.y * CGFloat(height)).rounded())
        guard (0..<width).contains(px), (0..<height).contains(py) else { return nil }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let pixel = base.advanced(by: py * rowBytes + px * MemoryLayout<Float32>.size)
            .assumingMemoryBound(to: Float32.self)
        let zDepth = pixel.pointee   // metres along the camera's forward axis
        guard zDepth.isFinite, zDepth > 0.1, zDepth < 5 else { return nil }

        // Depth is measured along camera-forward; convert to distance along
        // this (off-axis) ray so the pin lands exactly under the point.
        let forward = Self.forward(of: frame.camera.transform)
        let cosTheta = simd_dot(simd_normalize(ray.direction), forward)
        guard cosTheta > 0.1 else { return nil }
        return zDepth / cosTheta
    }

    // MARK: Camera-transform helpers

    // World-space position of the camera.
    private static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    // World-space forward direction of the camera (it looks down its -Z).
    private static func forward(of transform: simd_float4x4) -> SIMD3<Float> {
        -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    }

    // Renders what the user currently sees: the captured frame rotated
    // upright, center-cropped to the view's aspect ratio (matching the
    // view's aspect-fill), downscaled to ~1536px JPEG — enough detail for
    // the vision model to name small objects and place them accurately.
    // Because the crop matches the viewport exactly, the model's
    // normalized (x, y) maps straight onto view coordinates.
    private static func scanJPEG(frame: ARFrame, viewSize: CGSize) -> Data? {
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let extent = upright.extent
        let viewAspect = viewSize.width / viewSize.height

        var cropWidth = extent.width
        var cropHeight = extent.height
        if extent.width / extent.height > viewAspect {
            cropWidth = extent.height * viewAspect
        } else {
            cropHeight = extent.width / viewAspect
        }
        let cropRect = CGRect(
            x: extent.origin.x + (extent.width - cropWidth) / 2,
            y: extent.origin.y + (extent.height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        )
        let cropped = upright.cropped(to: cropRect)

        let context = CIContext()
        guard let cgImage = context.createCGImage(cropped, from: cropped.extent) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 1536 ? 1536 / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - ARSCNView host

struct ARViewContainer: UIViewRepresentable {
    let manager: ARSceneManager

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = manager.sceneView
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    // Drives the per-frame projection loop. ARSCNViewDelegate's render
    // callback fires on the SceneKit render thread; we hop to the main
    // actor to touch the observable manager.
    final class Coordinator: NSObject, ARSCNViewDelegate {
        private weak var manager: ARSceneManager?

        init(manager: ARSceneManager) {
            self.manager = manager
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            DispatchQueue.main.async { [weak manager] in
                MainActor.assumeIsolated {
                    manager?.onSceneUpdate()
                }
            }
        }
    }
}

// MARK: - Floating label bubble

// The in-scene label: target-language word (with transliteration when
// present) over the native translation. Collected state shows as a
// leading check; tapping toggles it. Black glass capsule so it reads on
// any camera background.
struct ARLabelBubble: View {
    let label: ARWordLabel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: label.isCollected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(label.isCollected ? .green : .white.opacity(0.8))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(label.item.word)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                            .foregroundStyle(.white)
                        if let translit = label.item.transliteration, !translit.isEmpty {
                            Text(translit)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Text(label.english)
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(label.isCollected ? 0.72 : 0.5)))
            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: label.isCollected)
    }
}
