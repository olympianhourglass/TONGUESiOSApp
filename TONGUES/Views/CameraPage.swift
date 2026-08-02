import SwiftUI
import AVFoundation

// Camera page for Create New Deck. Live AVFoundation preview cropped
// inside a rounded rectangle; the user aims at any object, taps the
// shutter, and we send the photo to Haiku 4.5 (vision) which returns
// the object's name in the chosen target language + dialect. The user
// can save the recognized word into an existing deck or seed a new
// one — same exit flow DeckResultsView uses.

// MARK: - AVFoundation glue

@Observable
@MainActor
final class CameraController {
    let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var configured = false
    // Retained while a single capture is in flight; reassigned each
    // shutter press so older delegates don't intercept later photos.
    @ObservationIgnored private var captureDelegate: PhotoCaptureDelegate?

    enum AuthState { case unknown, authorized, denied }
    var authState: AuthState = .unknown

    // Current optical/digital zoom factor of the active camera. Observable
    // so the on-screen indicator can track it. 1.0 = no zoom.
    var zoomFactor: CGFloat = 1.0

    // The active back-camera device, pulled from the session's inputs so we
    // don't have to thread a separate reference out of the detached
    // configuration task.
    @ObservationIgnored
    private var videoDevice: AVCaptureDevice? {
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.video) {
                return deviceInput.device
            }
        }
        return nil
    }

    // Upper zoom bound — the device's own ceiling, capped to a usable
    // digital range (beyond ~8× the image is too degraded to recognize).
    var maxZoom: CGFloat {
        guard let device = videoDevice else { return 5 }
        return min(device.maxAvailableVideoZoomFactor, 8)
    }

    // Applies a clamped zoom factor to the capture device. Both the live
    // preview and any subsequently captured photo reflect it, so a learner
    // can zoom in on a distant object or sign before tapping the shutter.
    func setZoom(_ factor: CGFloat) {
        guard let device = videoDevice else { return }
        let clamped = min(max(factor, 1.0), min(device.maxAvailableVideoZoomFactor, 8))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            // Zoom is a best-effort enhancement — ignore a transient lock
            // failure rather than surfacing an error.
        }
    }

    func resetZoom() { setZoom(1.0) }

    func startIfPermitted() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            authState = .authorized
            startSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authState = granted ? .authorized : .denied
            if granted { startSession() }
        case .denied, .restricted:
            authState = .denied
        @unknown default:
            authState = .denied
        }
    }

    func stop() {
        guard session.isRunning else { return }
        // AVCaptureSession start/stop must not run on the main thread.
        let session = session
        Task.detached(priority: .userInitiated) {
            session.stopRunning()
        }
    }

    // Awaitable stop used by the AR handoff: the ARKit session can't take
    // the camera until AVCapture has actually released it, so the caller
    // must be able to wait for stopRunning() to finish rather than guess
    // with a fixed delay.
    func stopAndWait() async {
        guard session.isRunning else { return }
        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    private func startSession() {
        let session = session
        let photoOutput = photoOutput
        let needsConfigure = !configured
        configured = true
        Task.detached(priority: .userInitiated) {
            if needsConfigure {
                session.beginConfiguration()
                session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                }
                session.commitConfiguration()
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        let settings = AVCapturePhotoSettings()
        let delegate = PhotoCaptureDelegate { [weak self] image in
            DispatchQueue.main.async {
                completion(image)
                self?.captureDelegate = nil
            }
        }
        captureDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void
    init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Page

struct CameraPage: View {
    @Binding var language: String
    @Binding var dialect: String
    let level: String
    let onAttributeTap: (DeckAttribute) -> Void
    let onSaved: () -> Void

    // Three ways to turn the viewfinder into cards: identify a physical
    // object (Haiku vision), read the text off a sign, or sweep the room
    // in AR and label every recognized object at once. The shutter
    // behaves differently per mode; the picker below the preview lets
    // the learner switch, mirroring the native Camera app's mode
    // selector. Object/Sign run on the AVCapture session; AR swaps in an
    // ARKit session — the mode switch hands the camera between the two
    // (they can't both hold it, which is why AR lives here rather than
    // on its own page).
    // Order here drives the on-screen tab order: AR first, then Sign,
    // then Object.
    enum CaptureMode: String, CaseIterable, Identifiable {
        case ar
        case sign
        case object

        var id: String { rawValue }
        var title: String {
            switch self {
            case .object: return "Object"
            case .sign: return "Sign"
            case .ar: return "AR"
            }
        }
        var systemImage: String {
            switch self {
            case .object: return "cube"
            case .sign: return "text.viewfinder"
            case .ar: return "arkit"
            }
        }
    }

    @State private var camera = CameraController()
    @State private var arManager = ARSceneManager()
    #if targetEnvironment(macCatalyst)
    // AR (ARKit) isn't available on Mac — open on Object scanning so Mac
    // doesn't land on a dead AR tab.
    @State private var mode: CaptureMode = .object
    #else
    // AR is the primary capture mode — the camera opens straight into it.
    @State private var mode: CaptureMode = .ar
    #endif
    @State private var identifiedItem: GeneratedItem?
    @State private var identifiedEnglish: String?
    @State private var isIdentifying = false
    @State private var errorText: String?
    @State private var showDeckPicker = false
    @State private var showCreateCover = false
    @State private var isSavingNewDeck = false
    // Zoom level captured at the start of a pinch, so each MagnifyGesture
    // scales relative to where the previous one left off.
    @State private var gestureBaseZoom: CGFloat = 1.0

    // Suggested-words web. Each detected result can be expanded into related
    // vocabulary the learner can add. AR expands each collected word once (up
    // to 3, non-recursive); Sign/Object expand the recognized item into 3
    // words that can themselves be expanded, growing a tree.
    // Roots keyed by AR label id (one per collected word).
    @State private var arSuggestionRoots: [UUID: WordSuggestionNode] = [:]
    // The Sign/Object recognized item's suggestion tree root.
    @State private var recognizedSuggestionRoot: WordSuggestionNode?
    // Words the learner tapped to add from the suggestion web; merged into the
    // save batch alongside the detected results.
    @State private var suggestedAdditions: [GeneratedItem] = []
    // Sign/Object suggestions grow recursively; cap the depth so the tree can't
    // run away. AR uses a depth of 1 (one level of leaves).
    private let signObjectSuggestionDepth = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                cameraSection
                attributesSection
                resultSection
                actionsSection
            }
            .padding(.horizontal, 8)
            // Clears the parent sheet's custom close-X overlay
            // (8pt top inset + 36pt circle = 44pt) plus breathing room.
            .padding(.top, 80)
            .padding(.bottom, 120) // leave room for the bottom toggle
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .task {
            if mode == .ar {
                await arManager.start(language: language, dialect: dialect)
            } else {
                await camera.startIfPermitted()
            }
        }
        // Keep the auto-scan loop labeling in the current target language
        // if the learner changes it while AR is open.
        .onChange(of: language) { _, newValue in
            arManager.updateLocale(language: newValue, dialect: dialect)
        }
        .onChange(of: dialect) { _, newValue in
            arManager.updateLocale(language: language, dialect: newValue)
        }
        .onDisappear {
            // Reset zoom so re-opening the camera starts framed at 1×.
            camera.resetZoom()
            gestureBaseZoom = 1.0
            camera.stop()
            arManager.pause()
        }
        .alert(L("Something went wrong"), isPresented: errorBinding) {
            Button(L("OK")) {
                errorText = nil
                arManager.errorText = nil
            }
        } message: {
            Text(errorText ?? arManager.errorText ?? "")
        }
        .sheet(isPresented: $showDeckPicker) {
            if !itemsForSave.isEmpty {
                DeckPickerSheet(
                    itemsToAdd: itemsForSave,
                    sourceLanguage: language,
                    sourceDialect: dialect,
                    onAdded: {
                        showDeckPicker = false
                        clearIdentification()
                        if mode == .ar { arManager.clearLabels() }
                        onSaved()
                    }
                )
            }
        }
        .sheet(isPresented: $showCreateCover) {
            if !itemsForSave.isEmpty {
                DeckCoverCustomizationSheet(
                    initialTitle: defaultDeckTitle,
                    language: language,
                    level: level
                ) { newTitle, chosenStyle, isPublic in
                    showCreateCover = false
                    let items = itemsForSave
                    Task {
                        await saveAsNewDeck(
                            items: items,
                            title: newTitle,
                            style: chosenStyle,
                            isPublic: isPublic
                        )
                    }
                }
                .presentationDetents([.fraction(0.8), .large])
            }
        }
    }

    // What the save flows operate on: the single identified item in
    // Object/Sign mode, or everything collected in AR mode — plus any words the
    // learner added from the suggestion web, deduped by word.
    private var itemsForSave: [GeneratedItem] {
        var base: [GeneratedItem] = mode == .ar
            ? arManager.collectedItems
            : (identifiedItem.map { [$0] } ?? [])
        var seen = Set(base.map { $0.word.lowercased() })
        for suggestion in suggestedAdditions where !seen.contains(suggestion.word.lowercased()) {
            base.append(suggestion)
            seen.insert(suggestion.word.lowercased())
        }
        // Every word gathered here — object, sign, AR label, or a suggestion —
        // is sourced from the camera.
        return base.map { $0.withSource(.camera) }
    }

    // MARK: Suggested words

    // Adds a suggested word to the save batch (idempotent by word). The node's
    // check state flips so the chip reflects that it's in.
    private func addSuggestion(_ node: WordSuggestionNode) {
        Haptics.light()
        node.isAdded = true
        if !suggestedAdditions.contains(where: { $0.word.lowercased() == node.item.word.lowercased() }) {
            suggestedAdditions.append(node.item)
        }
    }

    // Loads a node's related words (once). AR passes maxDepth 1; Sign/Object
    // pass the recursive cap. The avoid-list is every word currently on screen
    // so re-expanding never repeats one.
    private func expandSuggestion(_ node: WordSuggestionNode, maxDepth: Int) {
        guard node.depth < maxDepth, !node.isLoading, node.children.isEmpty else { return }
        node.isLoading = true
        node.errorText = nil
        let avoid = Array(wordsOnScreen())
        Task { @MainActor in
            do {
                let related = try await DeckGenerator.suggestRelatedWords(
                    to: node.item,
                    language: language,
                    dialect: dialect,
                    level: level,
                    count: 3,
                    avoid: avoid
                )
                node.children = related.map { WordSuggestionNode(item: $0, depth: node.depth + 1) }
                node.isLoading = false
            } catch {
                node.errorText = L("Couldn't load suggestions.")
                node.isLoading = false
            }
        }
    }

    // Union of every word already visible — detected results, collected AR
    // labels, all suggestion subtrees, and already-added suggestions — so the
    // model doesn't re-suggest duplicates.
    private func wordsOnScreen() -> Set<String> {
        var set = Set<String>()
        for label in arManager.labels { set.insert(label.item.word.lowercased()) }
        if let item = identifiedItem { set.insert(item.word.lowercased()) }
        for root in arSuggestionRoots.values { set.formUnion(root.wordsInSubtree()) }
        if let root = recognizedSuggestionRoot { set.formUnion(root.wordsInSubtree()) }
        for added in suggestedAdditions { set.insert(added.word.lowercased()) }
        return set
    }

    // Clears the suggestion web — called when a new item is recognized or the
    // batch is saved, so stale suggestions never carry over.
    private func resetSuggestions() {
        arSuggestionRoots = [:]
        recognizedSuggestionRoot = nil
        suggestedAdditions = []
    }

    // A pill that kicks off a suggestion expansion. Dark-themed to match the
    // camera surface.
    private func suggestTriggerButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 12))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var suggestionLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(L("Finding related words…"))
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 4)
    }

    private func suggestionErrorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(Color(red: 1.0, green: 0.6, blue: 0.6))
            Button {
                Haptics.light()
                retry()
            } label: {
                Text(L("Retry"))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // AR: one collected word's suggestion strip — a manual expand into up to 3
    // related words (leaves; not recursive). Aligned under the word text.
    @ViewBuilder
    private func arLabelSuggestions(for label: ARWordLabel) -> some View {
        let root = arSuggestionRoots[label.id]
        VStack(alignment: .leading, spacing: 8) {
            if let root, !root.children.isEmpty {
                SuggestionChildrenView(
                    nodes: root.children,
                    maxDepth: 1,
                    onAdd: addSuggestion,
                    onExpand: { _ in }
                )
            } else if let root, root.isLoading {
                suggestionLoadingRow
            } else if let root, let err = root.errorText {
                suggestionErrorRow(err) { expandSuggestion(root, maxDepth: 1) }
            } else {
                suggestTriggerButton(title: L("Suggested words")) {
                    let node = arSuggestionRoots[label.id] ?? WordSuggestionNode(item: label.item, depth: 0)
                    arSuggestionRoots[label.id] = node
                    expandSuggestion(node, maxDepth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 30)
        .padding(.bottom, 8)
    }

    // Sign/Object: the recognized item's recursive suggestion web — expand into
    // 3 words, each of which can be expanded again.
    @ViewBuilder
    private func recognizedSuggestions(for item: GeneratedItem) -> some View {
        if let root = recognizedSuggestionRoot {
            VStack(alignment: .leading, spacing: 10) {
                if !root.children.isEmpty {
                    SuggestionChildrenView(
                        nodes: root.children,
                        maxDepth: signObjectSuggestionDepth,
                        onAdd: addSuggestion,
                        onExpand: { expandSuggestion($0, maxDepth: signObjectSuggestionDepth) }
                    )
                } else if root.isLoading {
                    suggestionLoadingRow
                } else if let err = root.errorText {
                    suggestionErrorRow(err) { expandSuggestion(root, maxDepth: signObjectSuggestionDepth) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            suggestTriggerButton(title: L("Suggest related words")) {
                let node = WordSuggestionNode(item: item, depth: 0)
                recognizedSuggestionRoot = node
                expandSuggestion(node, maxDepth: signObjectSuggestionDepth)
            }
        }
    }

    // Hands the camera between the AVCapture session (Object/Sign) and
    // the ARKit session (AR). Only one can own the device at a time —
    // running them together is exactly the "camera isn't ready" failure
    // the old standalone AR page hit. The brief sleep lets the outgoing
    // session actually release the camera before the incoming one runs.
    private func switchSessions(toAR: Bool) async {
        if toAR {
            // Show the spinner (not a paused/black ARView) during the
            // handoff; start() flips it back to .supported once the AR
            // session is actually running.
            arManager.supportState = .checking
            // Wait for AVCapture to fully release the camera, then a short
            // buffer for the OS to hand it over, before ARKit claims it.
            await camera.stopAndWait()
            try? await Task.sleep(for: .milliseconds(250))
            await arManager.start(language: language, dialect: dialect)
        } else {
            arManager.pause()
            try? await Task.sleep(for: .milliseconds(250))
            await camera.startIfPermitted()
        }
    }

    // MARK: Camera section

    private var cameraSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black)
            if mode == .ar {
                arContent
            } else {
                switch camera.authState {
                case .authorized:
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                        // Pinch to zoom the lens in on a distant object or sign;
                        // the zoom carries through to the captured photo. Double-
                        // tap resets to 1×.
                        .gesture(zoomGesture)
                        .onTapGesture(count: 2) {
                            Haptics.light()
                            gestureBaseZoom = 1.0
                            camera.resetZoom()
                        }
                case .denied:
                    permissionDeniedView
                case .unknown:
                    ProgressView()
                        .tint(.white)
                }
            }
            VStack(spacing: 14) {
                Spacer()
                if mode == .ar, let hint = arManager.hintText {
                    Text(hint)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
                if camera.authState == .authorized || mode == .ar {
                    modePicker
                }
                if mode == .ar {
                    // Scanning is automatic as the camera pans, but the
                    // status pill doubles as a subtle manual scan button —
                    // tap it to label the current view on demand. Shows a
                    // spinner while a scan is in flight.
                    Button {
                        guard !arManager.isScanning, arManager.supportState == .supported else { return }
                        Haptics.medium()
                        Task { await arManager.scan(language: language, dialect: dialect) }
                    } label: {
                        arStatusPill
                    }
                    .buttonStyle(.plain)
                    .disabled(arManager.isScanning || arManager.supportState != .supported)
                    .padding(.bottom, 22)
                } else {
                    shutterButton
                        .padding(.bottom, 18)
                }
            }
        }
        // All three modes share the AR window's height so switching
        // between Object / Sign / AR doesn't resize the viewfinder.
        .frame(height: 420)
        // Zoom read-out, shown only while zoomed in. Matches the mode
        // picker's tinted-glass capsule so it reads on any camera feed.
        .overlay(alignment: .top) {
            if mode != .ar, camera.authState == .authorized, camera.zoomFactor > 1.05 {
                Text(String(format: "%.1f×", camera.zoomFactor))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                    .padding(.top, 14)
            }
        }
        // Clear-labels control for AR mode, kept out of the shutter row
        // so the shutter stays centered.
        .overlay(alignment: .topTrailing) {
            if mode == .ar, !arManager.labels.isEmpty {
                Button {
                    Haptics.light()
                    arManager.clearLabels()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    // AR viewfinder: the shared ARView plus label bubbles projected from
    // their world anchors. Coordinates line up because the overlay fills
    // the exact same frame as the ARView.
    @ViewBuilder
    private var arContent: some View {
        switch arManager.supportState {
        case .supported:
            ARViewContainer(manager: arManager)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                // Thin white leader lines connecting each bubble back to
                // the object it names, so a nudged-apart label still reads
                // as belonging to its object.
                .overlay {
                    Canvas { context, _ in
                        for label in arManager.labels {
                            guard let bubble = label.screenPoint,
                                  let object = label.anchorPoint,
                                  hypot(bubble.x - object.x, bubble.y - object.y) > 8 else { continue }
                            var line = Path()
                            line.move(to: bubble)
                            line.addLine(to: object)
                            context.stroke(line, with: .color(.white.opacity(0.65)), lineWidth: 1)
                            let dot = CGRect(x: object.x - 2.5, y: object.y - 2.5, width: 5, height: 5)
                            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.85)))
                        }
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    ForEach(arManager.labels) { label in
                        if let point = label.screenPoint {
                            ARLabelBubble(label: label) {
                                Haptics.light()
                                arManager.toggleCollected(label.id)
                            }
                            // screenPoint is the object point nudged apart
                            // from other labels; the leader line above ties
                            // it back to the object.
                            .position(x: point.x, y: point.y)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
        case .denied:
            permissionDeniedView
        case .unsupported:
            VStack(spacing: 8) {
                Image(systemName: "arkit")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.7))
                Text(L("AR isn't available on this device"))
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .foregroundStyle(.white)
                Text(L("Use Object mode to identify one thing at a time instead."))
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        case .checking:
            ProgressView()
                .tint(.white)
        }
    }

    // Pinch-to-zoom over the viewfinder. Each gesture scales relative to the
    // zoom level it started at; the controller clamps to the device range.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                camera.setZoom(gestureBaseZoom * value.magnification)
            }
            .onEnded { _ in
                gestureBaseZoom = camera.zoomFactor
            }
    }

    // Segmented Object / Sign selector floating over the bottom of the
    // viewfinder. Tinted glass capsule so it reads on any camera feed.
    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { candidate in
                Button {
                    guard mode != candidate else { return }
                    Haptics.light()
                    let wasAR = mode == .ar
                    withAnimation(.easeInOut(duration: 0.18)) {
                        mode = candidate
                    }
                    // A pending result from the other mode would read as
                    // stale, so clear it when the learner switches intent.
                    clearIdentification()
                    // Crossing the AVCapture ↔ ARKit boundary hands the
                    // camera between sessions. Object ↔ Sign shares the
                    // capture session, so no handoff there.
                    if wasAR != (candidate == .ar) {
                        Task { await switchSessions(toAR: candidate == .ar) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(L(candidate.title))
                            .font(.custom("NeueHaasDisplay-Medium", size: 13))
                    }
                    .foregroundStyle(mode == candidate ? .black : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        if mode == candidate {
                            Capsule().fill(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                // Only block switching during a one-shot photo identify;
                // the AR auto-scan runs continuously, so gating on it
                // would leave the chips disabled most of the time.
                .disabled(isIdentifying)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.7))
            Text(L("Camera access required"))
                .font(.custom("NeueHaasDisplay-Light", size: 16))
                .foregroundStyle(.white)
            Text(L("Enable Camera for TONGUES in Settings to identify objects."))
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // Live status for AR mode. Labels appear on their own; this just
    // tells the learner the scanner is working (or idle-ready).
    private var arStatusPill: some View {
        HStack(spacing: 8) {
            if arManager.isScanning {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
                Text(L("Looking around…"))
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 13, weight: .medium))
                Text(L(arManager.labels.isEmpty ? "Point at objects · tap to scan" : "Keep panning · tap to scan"))
            }
        }
        .font(.custom("NeueHaasDisplay-Medium", size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.4)))
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var shutterButton: some View {
        Button {
            Haptics.medium()
            if mode == .ar {
                Task { await arManager.scan(language: language, dialect: dialect) }
            } else {
                captureAndIdentify()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 76, height: 76)
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 64, height: 64)
                if isBusy {
                    ProgressView().tint(.white)
                } else if mode == .ar {
                    // Reticle glyph reads as "scan the scene" rather than
                    // "take one photo".
                    Image(systemName: "viewfinder")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    Circle().fill(.white).frame(width: 52, height: 52)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(shutterDisabled)
    }

    private var isBusy: Bool {
        isIdentifying || arManager.isScanning
    }

    private var shutterDisabled: Bool {
        if mode == .ar {
            return arManager.supportState != .supported || arManager.isScanning
        }
        return camera.authState != .authorized || isIdentifying
    }

    // MARK: Attributes (language + dialect only)

    // Horizontal scroll so wide "label + selection" chips never push past
    // the screen bounds (or skew the rest of the page wider). The leftmost
    // chip inherits the parent VStack's 8pt leading inset.
    private var attributesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 10) {
                attribute(.language, value: language)
                attribute(.dialect, value: dialect)
            }
        }
    }

    // Mirrors the Generate page's glass-pill style so the Camera page reads
    // visually consistent — label + selection on a single line, tinted white
    // for this page's dark background (label solid, value lighter opacity).
    private func attribute(_ kind: DeckAttribute, value: String) -> some View {
        Button {
            Haptics.light()
            onAttributeTap(kind)
        } label: {
            HStack(spacing: 6) {
                Text(L(kind.title))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.white)
                Text(localizedAttributeValue(value, for: kind))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: Result section

    @ViewBuilder
    private var resultSection: some View {
        if mode == .ar {
            collectedSection
        } else {
            recognizedSection
        }
    }

    // AR mode: the running list of labels the scan pinned, each
    // toggleable in/out of the batch that the save flows operate on.
    private var collectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Collected"))
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)

            if arManager.labels.isEmpty {
                Text(L("Just point your camera around the room — labels appear automatically on everything we recognize. Tap a label to keep it or drop it."))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(arManager.labels) { label in
                        Button {
                            Haptics.light()
                            arManager.toggleCollected(label.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: label.isCollected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(label.isCollected ? .white : Color.white.opacity(0.4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label.item.word)
                                        .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                                        .foregroundStyle(.white)
                                    HStack(spacing: 6) {
                                        Text(label.english)
                                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                                            .foregroundStyle(.white.opacity(0.6))
                                        if let translit = label.item.transliteration, !translit.isEmpty {
                                            Text(translit)
                                                .font(.system(size: 12))
                                                .italic()
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        arLabelSuggestions(for: label)
                        if label.id != arManager.labels.last?.id {
                            Divider().overlay(Color.white.opacity(0.12))
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    private var recognizedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Recognized"))
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)
            if let item = identifiedItem, let english = identifiedEnglish {
                VStack(alignment: .leading, spacing: 6) {
                    Text(english)
                        .font(.custom("NeueHaasDisplay-Light", size: 22))
                        .foregroundStyle(.white)
                    Text(item.word)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 28))
                        .foregroundStyle(.white)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .padding(.horizontal, 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

                recognizedSuggestions(for: item)
            } else {
                Text(L(placeholderText))
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }

    private var placeholderText: String {
        if isIdentifying {
            return mode == .sign ? "Reading the sign…" : "Identifying…"
        }
        switch mode {
        case .object: return "Tap the shutter to identify what you're pointing at."
        case .sign: return "Tap the shutter to read the text on a sign."
        case .ar: return "Point your camera around — labels appear automatically."
        }
    }

    // MARK: Action buttons (mirror DeckResultsView's ActionCard row)

    private var actionsSection: some View {
        HStack(spacing: 12) {
            ActionCard(
                title: L(isSavingNewDeck ? "Saving…" : "Create New Deck"),
                systemImage: isSavingNewDeck ? "arrow.up.circle" : "square.stack.3d.up",
                isPrimary: false,
                inverted: true
            ) {
                Haptics.medium()
                showCreateCover = true
            }
            .disabled(itemsForSave.isEmpty || isSavingNewDeck)
            ActionCard(title: L("Save to Deck"), systemImage: "plus.circle", isPrimary: true, inverted: true) {
                Haptics.medium()
                showDeckPicker = true
            }
            .disabled(itemsForSave.isEmpty || isSavingNewDeck)
        }
    }

    // MARK: Capture + identify

    private func captureAndIdentify() {
        guard !isIdentifying else { return }
        isIdentifying = true
        camera.capture { image in
            guard let image else {
                isIdentifying = false
                errorText = L("Couldn't read the photo. Try again.")
                return
            }
            // Both modes send a ~1024px JPEG to the vision model — small
            // enough to keep upload + token cost down, detailed enough to
            // read an object or the text on a sign.
            guard let jpeg = image.tongues_downscaledJPEG(maxDimension: 1024, quality: 0.85) else {
                isIdentifying = false
                errorText = L("Couldn't encode the photo. Try again.")
                return
            }
            switch mode {
            case .object:
                Task { await identify(imageData: jpeg) }
            case .sign:
                Task { await readSignage(imageData: jpeg) }
            case .ar:
                // AR never routes here — its shutter calls arManager.scan
                // directly. Reset the flag defensively so a stray call
                // can't wedge the shutter.
                isIdentifying = false
            }
        }
    }

    // Sign mode: read the sign's text and translate it in one vision call
    // (robust across scripts, unlike on-device OCR). Produces the same
    // GeneratedItem shape the object path does, so every downstream save
    // flow just works.
    @MainActor
    private func readSignage(imageData: Data) async {
        defer { isIdentifying = false }
        do {
            let result = try await DeckGenerator.readSign(
                imageData: imageData,
                language: language,
                dialect: dialect
            )
            Haptics.success()
            // Fresh reading — drop any suggestion web from a prior sign.
            resetSuggestions()
            identifiedItem = result.item
            identifiedEnglish = result.englishLabel
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func identify(imageData: Data) async {
        defer { isIdentifying = false }
        do {
            let result = try await DeckGenerator.identifyObject(
                imageData: imageData,
                language: language,
                dialect: dialect
            )
            Haptics.success()
            // Fresh identification — drop any suggestion web from a prior object.
            resetSuggestions()
            identifiedItem = result.item
            identifiedEnglish = result.englishLabel
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private func clearIdentification() {
        identifiedItem = nil
        identifiedEnglish = nil
        resetSuggestions()
    }

    // Deterministic default title for the brand-new deck path — covers
    // both the single-item (Object/Sign) and multi-item (AR) cases so
    // the user doesn't have to invent one. Overridable in the cover sheet.
    private var defaultDeckTitle: String {
        let items = itemsForSave
        switch mode {
        case .ar:
            guard let first = items.first else { return "AR Scan" }
            let label = first.translation.capitalized
            return items.count > 1 ? "\(label) & More – AR Scan" : "\(label) – AR Scan"
        case .sign:
            let label = identifiedEnglish?.capitalized ?? items.first?.translation.capitalized ?? "Sign"
            return "\(label) – Sign"
        case .object:
            let label = identifiedEnglish?.capitalized ?? items.first?.translation.capitalized ?? "Object"
            return "\(label) – Camera Find"
        }
    }

    @MainActor
    private func saveAsNewDeck(
        items: [GeneratedItem],
        title: String,
        style: DeckCoverStyle,
        isPublic: Bool
    ) async {
        guard !items.isEmpty else { return }
        isSavingNewDeck = true
        defer { isSavingNewDeck = false }
        let deck = GeneratedDeck(
            title: title,
            items: items.map { $0.withLanguage(language) },
            language: language,
            dialect: dialect,
            level: level,
            contentType: "Words",
            amount: "\(items.count)",
            tones: [],
            interests: [],
            userPrompt: mode == .ar ? "AR scan" : "Camera scan",
            promptSent: "",
            rawJSON: ""
        )
        do {
            _ = try await FirebaseDeckService.saveDeck(
                deck,
                title: title,
                coverStyle: style.rawValue,
                isPublic: isPublic
            )
            Haptics.success()
            clearIdentification()
            if mode == .ar { arManager.clearLabels() }
            onSaved()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }
}

// Reuses the same downscale helper ProfileView uses for avatar uploads.
// Lives here as an internal extension so CameraPage works without
// coupling to ProfileView.swift's private extension.
private extension UIImage {
    func tongues_downscaledJPEG(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
