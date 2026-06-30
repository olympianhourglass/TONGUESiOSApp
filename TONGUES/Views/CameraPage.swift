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

    @State private var camera = CameraController()
    @State private var identifiedItem: GeneratedItem?
    @State private var identifiedEnglish: String?
    @State private var isIdentifying = false
    @State private var errorText: String?
    @State private var showDeckPicker = false
    @State private var showCreateCover = false
    @State private var isSavingNewDeck = false

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
        .scrollDismissesKeyboard(.interactively)
        .task { await camera.startIfPermitted() }
        .onDisappear { camera.stop() }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $showDeckPicker) {
            if let item = identifiedItem {
                DeckPickerSheet(
                    itemsToAdd: [item],
                    sourceLanguage: language,
                    sourceDialect: dialect,
                    onAdded: {
                        showDeckPicker = false
                        clearIdentification()
                        onSaved()
                    }
                )
            }
        }
        .sheet(isPresented: $showCreateCover) {
            if let item = identifiedItem {
                DeckCoverCustomizationSheet(
                    initialTitle: deckTitle(for: item),
                    language: language,
                    level: level
                ) { newTitle, chosenStyle, isPublic in
                    showCreateCover = false
                    Task {
                        await saveAsNewDeck(
                            item: item,
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

    // MARK: Camera section

    private var cameraSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black)
            switch camera.authState {
            case .authorized:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            case .denied:
                permissionDeniedView
            case .unknown:
                ProgressView()
                    .tint(.white)
            }
            VStack {
                Spacer()
                shutterButton
                    .padding(.bottom, 18)
            }
        }
        .frame(height: 360)
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

    private var shutterButton: some View {
        Button {
            Haptics.medium()
            captureAndIdentify()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 76, height: 76)
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 64, height: 64)
                if isIdentifying {
                    ProgressView().tint(.white)
                } else {
                    Circle().fill(.white).frame(width: 52, height: 52)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.authState != .authorized || isIdentifying)
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

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recognized")
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            if let item = identifiedItem, let english = identifiedEnglish {
                VStack(alignment: .leading, spacing: 6) {
                    Text(english)
                        .font(.custom("PlayfairDisplay-Regular", size: 22))
                        .foregroundStyle(.black)
                    Text(item.word)
                        .font(.custom("PlayfairDisplay-Regular", size: 28))
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
                Text(isIdentifying ? "Identifying…" : "Tap the shutter to identify what you're pointing at.")
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
            .disabled(identifiedItem == nil || isSavingNewDeck)
            ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
                Haptics.medium()
                showDeckPicker = true
            }
            .disabled(identifiedItem == nil || isSavingNewDeck)
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
            // Match the existing avatar pipeline: ~1024px JPEG keeps
            // upload + token cost small without losing identifiable
            // detail.
            guard let jpeg = image.tongues_downscaledJPEG(maxDimension: 1024, quality: 0.85) else {
                isIdentifying = false
                errorText = "Couldn't encode the photo. Try again."
                return
            }
            Task { await identify(imageData: jpeg) }
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

    private func deckTitle(for item: GeneratedItem) -> String {
        // Cheap, deterministic title for the brand-new deck path so the
        // user doesn't have to invent one. They can override it in the
        // cover customization sheet.
        let label = identifiedEnglish?.capitalized ?? item.translation.capitalized
        return "\(label) – Camera Find"
    }

    @MainActor
    private func saveAsNewDeck(
        item: GeneratedItem,
        title: String,
        style: DeckCoverStyle,
        isPublic: Bool
    ) async {
        isSavingNewDeck = true
        defer { isSavingNewDeck = false }
        let deck = GeneratedDeck(
            title: title,
            items: [item.withLanguage(language)],
            language: language,
            dialect: dialect,
            level: level,
            contentType: "Words",
            amount: "1",
            tones: [],
            interests: [],
            userPrompt: "Camera scan",
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
