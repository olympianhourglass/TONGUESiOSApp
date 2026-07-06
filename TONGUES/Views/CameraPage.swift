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
    // AR is the primary capture mode — the camera opens straight into it.
    @State private var mode: CaptureMode = .ar
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
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") {
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
    // Object/Sign mode, or everything collected in AR mode.
    private var itemsForSave: [GeneratedItem] {
        if mode == .ar {
            return arManager.collectedItems
        }
        return identifiedItem.map { [$0] } ?? []
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
        .frame(height: mode == .ar ? 420 : 360)
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
                Text("AR isn't available on this device")
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .foregroundStyle(.white)
                Text("Use Object mode to identify one thing at a time instead.")
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
                        Text(candidate.title)
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
            Text("Camera access required")
                .font(.custom("NeueHaasDisplay-Light", size: 16))
                .foregroundStyle(.white)
            Text("Enable Camera for TONGUES in Settings to identify objects.")
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
                Text("Looking around…")
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 13, weight: .medium))
                Text(arManager.labels.isEmpty ? "Point at objects · tap to scan" : "Keep panning · tap to scan")
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

    private var attributesSection: some View {
        HStack(alignment: .top, spacing: 12) {
            attribute(.language, value: language)
            attribute(.dialect, value: dialect)
            Spacer(minLength: 0)
        }
    }

    // Mirrors the AttributesRow tile style so the Camera page reads
    // visually consistent with the Generate page — same chevron pill,
    // same font, same tap behavior driven by the parent sheet's
    // existing attribute picker.
    private func attribute(_ kind: DeckAttribute, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(.black)
                .lineLimit(1)
            Button {
                Haptics.light()
                onAttributeTap(kind)
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
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
            Text("Collected")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if arManager.labels.isEmpty {
                Text("Just point your camera around the room — labels appear automatically on everything we recognize. Tap a label to keep it or drop it.")
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.92), lineWidth: 1)
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
                                    .foregroundStyle(label.isCollected ? .black : Color(white: 0.75))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label.item.word)
                                        .font(.custom("NeueHaasDisplay-Mediu", size: 17))
                                        .foregroundStyle(.black)
                                    HStack(spacing: 6) {
                                        Text(label.english)
                                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                                            .foregroundStyle(.secondary)
                                        if let translit = label.item.transliteration, !translit.isEmpty {
                                            Text(translit)
                                                .font(.system(size: 12))
                                                .italic()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if label.id != arManager.labels.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
            }
        }
    }

    private var recognizedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recognized")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            if let item = identifiedItem, let english = identifiedEnglish {
                VStack(alignment: .leading, spacing: 6) {
                    Text(english)
                        .font(.custom("NeueHaasDisplay-Light", size: 22))
                        .foregroundStyle(.black)
                    Text(item.word)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 28))
                        .foregroundStyle(.black)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .padding(.horizontal, 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
            } else {
                Text(placeholderText)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.92), lineWidth: 1)
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
                title: isSavingNewDeck ? "Saving…" : "Create New Deck",
                systemImage: isSavingNewDeck ? "arrow.up.circle" : "square.stack.3d.up",
                isPrimary: false
            ) {
                Haptics.medium()
                showCreateCover = true
            }
            .disabled(itemsForSave.isEmpty || isSavingNewDeck)
            ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
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
                errorText = "Couldn't read the photo. Try again."
                return
            }
            // Both modes send a ~1024px JPEG to the vision model — small
            // enough to keep upload + token cost down, detailed enough to
            // read an object or the text on a sign.
            guard let jpeg = image.tongues_downscaledJPEG(maxDimension: 1024, quality: 0.85) else {
                isIdentifying = false
                errorText = "Couldn't encode the photo. Try again."
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
