import SwiftUI
import SceneKit
import UIKit
import CoreHaptics

// 3D rotatable card tile used on SessionIntroView. Renders the deck's
// cardback to a UIImage texture (front face) and a black-with-TONGUES
// texture (back face), then hands them to an SCNView wrapping a thin,
// rounded-edge SCNBox so the user can flick the card around with a pan
// gesture before tapping Begin.
//
// Layout note: the visible card size is set by the parent's frame, but
// the internal SCNView extends `canvasMultiplier`x beyond that frame as
// a background-layer overlay. The camera is pulled back by the same
// factor so the card's on-screen size stays constant — the extra canvas
// only exists to give the card room to swing into without ever clipping
// against the SCNView edges. Surrounding SwiftUI text is unaffected
// because the outer reported frame doesn't change.
struct DeckCard3DTile: View {
    let style: DeckCoverStyle
    var aspectRatio: CGFloat = 90.0 / 53.0
    // Extra canvas around the card so even at extreme rotations the
    // card never crops against the SCNView edges. The scene's camera
    // gets pulled back by the same factor, so the card looks the same
    // size on screen — only the surrounding black canvas grows.
    var canvasMultiplier: CGFloat = 1.6

    @Environment(\.displayScale) private var displayScale
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if let frontImage, let backImage {
                        RotatableCardSceneView(
                            frontImage: frontImage,
                            backImage: backImage,
                            aspectRatio: aspectRatio,
                            cameraDistance: canvasMultiplier
                        )
                        .frame(
                            width: geo.size.width * canvasMultiplier,
                            height: geo.size.height * canvasMultiplier
                        )
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            }
            .task(id: style) {
                await renderTextures()
            }
    }

    @MainActor
    private func renderTextures() async {
        // Video cardbacks lean on `CardbackThumbnailCache` for their
        // still-frame poster. DeckCoverFill loads this asynchronously,
        // but we render the texture synchronously below, so we have to
        // prime the cache up front — otherwise video styles would bake
        // out as the solid black backing color.
        if let resource = style.videoResourceName,
           CardbackThumbnailCache.image(for: resource) == nil {
            await CardbackThumbnailCache.prepare(for: resource)
        }

        let textureWidth: CGFloat = 540
        let textureHeight: CGFloat = textureWidth / aspectRatio

        // Plain-rectangle textures — the rounded face corners and the
        // white edges come from the SCNBox's chamfer + edge materials,
        // not from baked-in alpha.
        let frontView = ZStack {
            style.fill()
            if let resource = style.videoResourceName,
               let poster = CardbackThumbnailCache.image(for: resource) {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: textureWidth, height: textureHeight)

        let frontRenderer = ImageRenderer(content: frontView)
        frontRenderer.scale = displayScale
        frontImage = frontRenderer.uiImage

        let backView = ZStack {
            Color.black
            TonguesWordmark(size: textureHeight * 0.175)
                .foregroundStyle(.white)
        }
        .frame(width: textureWidth, height: textureHeight)

        let backRenderer = ImageRenderer(content: backView)
        backRenderer.scale = displayScale
        backImage = backRenderer.uiImage
    }
}

// SceneKit-backed card built from an extruded SCNShape with a rounded
// rect path — decoupling the face corner radius from the slab
// thickness so the card can stay very thin while still showing a
// pronounced rounded corner. Three materials cover the front face,
// back face, and extruded perimeter. Faces use the Blinn lighting
// model with a moderate specular term so a directional key light
// gives the card a soft moving highlight as the user rotates it.
// A pan gesture rotates the card freely on both axes and continues
// to glide after release so the motion feels weighted, not static.
struct RotatableCardSceneView: UIViewRepresentable {
    let frontImage: UIImage
    let backImage: UIImage
    let aspectRatio: CGFloat
    // Camera Z position. Scales with the SCNView's canvas expansion so
    // the projected card size stays constant on screen regardless of
    // how much breathing room the wrapping container added.
    var cameraDistance: CGFloat = 1.0

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.isOpaque = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false

        let scene = SCNScene()
        scene.background.contents = UIColor.black
        view.scene = scene

        let cardWidth: CGFloat = 1.0
        let cardHeight: CGFloat = cardWidth / aspectRatio
        // Quarter the previous slab thickness for a sharper
        // playing-card profile. Face corner radius comes from the
        // bezier path below rather than the geometry's edge chamfer,
        // so it can stay correctly scaled even though the slab is
        // paper-thin. Ratio matches the Study page deck cover
        // (cornerRadius 4 over 220pt width ≈ 0.0182) so the same
        // card silhouette carries across screens.
        let thickness: CGFloat = 0.0055
        let faceCornerRadius: CGFloat = 0.018
        let edgeRound: CGFloat = thickness / 2

        let cardRect = CGRect(
            x: -cardWidth / 2,
            y: -cardHeight / 2,
            width: cardWidth,
            height: cardHeight
        )
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: faceCornerRadius)
        // Tighten the path's flatness so SceneKit samples the corner
        // arcs densely when it tessellates the CGPath — keeps the
        // rounded corners smooth instead of visibly faceted.
        cardPath.flatness = 0.001

        let shape = SCNShape(path: cardPath, extrusionDepth: thickness)
        // Soft rolloff where the face meets the perimeter so the slab
        // never reads as a paper-cut silhouette under the key light.
        shape.chamferRadius = edgeRound
        shape.materials = makeMaterials()
        let cardNode = SCNNode(geometry: shape)
        cardNode.name = "card"
        // Head-on view at rest — the user reads the card as a flat
        // image first and only discovers the 3D-ness when they grab it.
        cardNode.eulerAngles = SCNVector3Zero
        scene.rootNode.addChildNode(cardNode)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Float(cameraDistance))
        scene.rootNode.addChildNode(cameraNode)

        // Key directional light from upper-front-left. Positioned via
        // look(at:) so the light direction always aims at the card
        // origin, producing a soft top-left highlight when the card
        // sits head-on and sweeping across the face as it rotates.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.light?.color = UIColor.white
        key.position = SCNVector3(-0.7, 0.9, 1.4)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        // Soft ambient fill so the card never reads as silhouetted —
        // real cards in a room always have some bounced light.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        context.coordinator.cardNode = cardNode

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let card = context.coordinator.cardNode,
              let materials = card.geometry?.materials,
              materials.count >= 3 else { return }
        // Extruded SCNShape material order: front face, back face,
        // perimeter. Front and back swap in when the textures finish
        // rendering — the perimeter material stays white.
        materials[0].diffuse.contents = frontImage
        materials[1].diffuse.contents = backImage

        if let cameraNode = uiView.scene?.rootNode.childNodes.first(where: { $0.camera != nil }) {
            cameraNode.position.z = Float(cameraDistance)
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopGlide()
        coordinator.stopHapticForDismantle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // Three materials, indexed to SCNShape's extrusion order. Faces
    // use Blinn lighting with a moderate specular term so the
    // directional key light produces the soft varnish-like sheen of
    // a real playing card. The perimeter strip gets a slightly muted
    // near-white finish, like the exposed paper edge of a stacked deck.
    private func makeMaterials() -> [SCNMaterial] {
        let front = SCNMaterial()
        front.diffuse.contents = frontImage
        front.lightingModel = .blinn
        front.specular.contents = UIColor(white: 0.65, alpha: 1)
        front.shininess = 0.45
        front.isDoubleSided = false

        let back = SCNMaterial()
        back.diffuse.contents = backImage
        back.lightingModel = .blinn
        back.specular.contents = UIColor(white: 0.65, alpha: 1)
        back.shininess = 0.45
        back.isDoubleSided = false

        let edge = SCNMaterial()
        edge.diffuse.contents = UIColor(white: 0.95, alpha: 1)
        edge.lightingModel = .blinn
        edge.specular.contents = UIColor(white: 0.5, alpha: 1)
        edge.shininess = 0.3

        // Order: front face, back face, extruded perimeter.
        return [front, back, edge]
    }

    final class Coordinator: NSObject {
        weak var cardNode: SCNNode?

        // Angular velocity (radians/sec) carried over from the user's
        // last pan, decayed each display-link tick so the card glides
        // to a stop instead of locking the instant they lift off.
        private var angularVelocityX: Float = 0
        private var angularVelocityY: Float = 0
        private var glideLink: CADisplayLink?
        private var lastGlideTick: CFTimeInterval = 0

        // Continuous CoreHaptics rumble whose intensity tracks the
        // card's current angular speed, so a hard flick produces a
        // deep resonant buzz while a slow drag is near-silent. The
        // engine is created lazily and silently absent on unsupported
        // hardware.
        private var hapticEngine: CHHapticEngine?
        private var continuousHapticPlayer: CHHapticAdvancedPatternPlayer?
        private var isHapticPlaying = false
        // Angular speed (rad/sec) that maps to peak haptic intensity.
        // Matches the glide cap so a maxed-out flick saturates the
        // rumble while leaving headroom for gentler motion below it.
        private let hapticReferenceSpeed: Float = 8.0

        override init() {
            super.init()
            prepareHaptics()
        }

        deinit {
            stopGlide()
            try? continuousHapticPlayer?.stop(atTime: 0)
            hapticEngine?.stop()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let cardNode, let view = recognizer.view else { return }
            // ~180° of rotation per screen-width pan — responsive without
            // the card whipping past the user's grip on small motions.
            let sensitivity: CGFloat = .pi / 180

            switch recognizer.state {
            case .began:
                stopGlide()
                startHaptic()
                updateHapticIntensity(forSpeed: 0)
            case .changed:
                let translation = recognizer.translation(in: view)
                cardNode.eulerAngles.y += Float(translation.x * sensitivity)
                cardNode.eulerAngles.x += Float(translation.y * sensitivity)
                recognizer.setTranslation(.zero, in: view)

                // Drive the rumble from the finger's instantaneous
                // velocity, not the accumulated translation — that's
                // what makes a quick whip feel sharply different
                // from a slow drag of the same total distance.
                let velocity = recognizer.velocity(in: view)
                let vx = Float(velocity.y * sensitivity)
                let vy = Float(velocity.x * sensitivity)
                updateHapticIntensity(forSpeed: hypot(vx, vy))
            case .ended:
                let velocity = recognizer.velocity(in: view)
                // Cap the per-axis glide speed so a hard flick doesn't
                // send the card into a blur — anything above ~1.3
                // rotations/sec stops feeling like a card and starts
                // feeling like a fidget spinner.
                let maxSpeed: Float = 8.0
                angularVelocityY = clamp(Float(velocity.x * sensitivity), to: maxSpeed)
                angularVelocityX = clamp(Float(velocity.y * sensitivity), to: maxSpeed)
                startGlide()
            case .cancelled, .failed:
                stopGlide()
                stopHaptic()
            default:
                break
            }
        }

        private func clamp(_ value: Float, to limit: Float) -> Float {
            min(max(value, -limit), limit)
        }

        private func startGlide() {
            stopGlide()
            lastGlideTick = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tickGlide))
            link.add(to: .main, forMode: .common)
            glideLink = link
        }

        func stopGlide() {
            glideLink?.invalidate()
            glideLink = nil
        }

        @objc private func tickGlide() {
            guard let cardNode else {
                stopGlide()
                stopHaptic()
                return
            }
            let now = CACurrentMediaTime()
            // Clamp dt so a stalled frame doesn't translate into a
            // sudden lurch when the display link catches back up.
            let dt = Float(min(now - lastGlideTick, 1.0 / 30))
            lastGlideTick = now

            cardNode.eulerAngles.y += angularVelocityY * dt
            cardNode.eulerAngles.x += angularVelocityX * dt

            // Exponential friction tuned so a typical flick settles
            // within ~1.5s — long enough to feel like the card has
            // weight, short enough that the user can swipe again
            // without waiting for it to fully come to rest.
            let friction: Float = 2.4
            let decay = exp(-friction * dt)
            angularVelocityX *= decay
            angularVelocityY *= decay

            // Let the rumble decay alongside the spin so the haptic
            // tapers into silence at the same moment the visual
            // motion does.
            updateHapticIntensity(forSpeed: hypot(angularVelocityX, angularVelocityY))

            // ~0.5°/sec — below the threshold where residual motion is
            // perceptible, so we can stop spending display-link ticks.
            if abs(angularVelocityX) < 0.009 && abs(angularVelocityY) < 0.009 {
                stopGlide()
                stopHaptic()
            }
        }

        // MARK: - Haptics

        private func prepareHaptics() {
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            do {
                let engine = try CHHapticEngine()
                engine.isAutoShutdownEnabled = true
                // If the system resets or stops the engine (background,
                // audio-session interruption, etc.) the player handle
                // becomes invalid. Rebuild on the next interaction.
                engine.resetHandler = { [weak self] in
                    self?.isHapticPlaying = false
                    try? self?.hapticEngine?.start()
                }
                engine.stoppedHandler = { [weak self] _ in
                    self?.isHapticPlaying = false
                }
                try engine.start()
                hapticEngine = engine

                // Continuous event with a long duration so we can
                // start/stop it on demand and just live-update its
                // intensity/sharpness as the rotation speed changes.
                // Baseline sharpness is low for a deep "resonant"
                // rumble rather than a clicky tap.
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [intensity, sharpness],
                    relativeTime: 0,
                    duration: 600
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                continuousHapticPlayer = try engine.makeAdvancedPlayer(with: pattern)
            } catch {
                // Engine creation failed — haptics will be absent.
            }
        }

        private func startHaptic() {
            guard let player = continuousHapticPlayer, !isHapticPlaying else { return }
            do {
                try hapticEngine?.start()
                try player.start(atTime: 0)
                isHapticPlaying = true
            } catch {
                isHapticPlaying = false
            }
        }

        private func stopHaptic() {
            guard let player = continuousHapticPlayer, isHapticPlaying else { return }
            try? player.stop(atTime: 0)
            isHapticPlaying = false
        }

        func stopHapticForDismantle() {
            stopHaptic()
            hapticEngine?.stop()
        }

        private func updateHapticIntensity(forSpeed speed: Float) {
            guard let player = continuousHapticPlayer, isHapticPlaying else { return }
            let normalized = min(max(speed / hapticReferenceSpeed, 0), 1)
            // Slight concave curve so the rumble grows quickly out of
            // silence on gentle motion, then plateaus as the user
            // approaches the harsh-flick end of the range.
            let intensityValue = pow(normalized, 0.7)
            // Sharpness drifts up with speed so a hard flick feels
            // edgier on top of the baseline resonant buzz.
            let sharpnessValue = 0.2 + normalized * 0.3
            let parameters = [
                CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: intensityValue,
                    relativeTime: 0
                ),
                CHHapticDynamicParameter(
                    parameterID: .hapticSharpnessControl,
                    value: sharpnessValue,
                    relativeTime: 0
                )
            ]
            try? player.sendParameters(parameters, atTime: 0)
        }
    }
}
