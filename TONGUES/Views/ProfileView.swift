import SwiftUI
import FirebaseAuth
import UIKit

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthService.shared
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showLogoutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showFeedbackSheet = false
    @State private var activeEditField: ProfileEditField?
    @State private var showAllInterests = false
    @State private var showAvatarSourceChooser = false
    @State private var activeImagePickerSource: ImagePickerSource?
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String?

    // How many interest chips to show before the "View more" toggle.
    private let collapsedInterestsCount = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    accountHeader
                        .padding(.top, 8)

                    if let onboarding = profile?.onboarding {
                        section("Languages", editField: .languages) {
                            let prefs = onboarding.languagePreferences ?? []
                            if prefs.isEmpty {
                                emptyValue("No languages on file yet.")
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(prefs) { pref in
                                        Text("\(pref.language) · \(pref.dialect) · \(pref.level)")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(Color(white: 0.93)))
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                        }

                        section("Travel destinations", editField: .destinations) {
                            let destinations = onboarding.destinations ?? []
                            if destinations.isEmpty {
                                emptyValue("No destinations on file yet.")
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(destinations) { dest in
                                        Text("· \(dest.name)")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.black)
                                    }
                                }
                            }
                        }

                        section("What you'd love to understand", editField: .understand) {
                            if let understand = onboarding.firstUnderstand, !understand.isEmpty {
                                Text(understand)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.black)
                            } else {
                                emptyValue("Tap Edit to pick one.")
                            }
                        }

                        interestsSection(onboarding: onboarding)

                        WordCycleWidgetSection()

                        LockScreenWidgetSection()
                    } else if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if let loadError {
                        Text(loadError)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 32)

                    VStack(spacing: 12) {
                        feedbackButton
                        logoutButton
                        deleteAccountButton
                    }
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.black)
                }
            }
            .task { await loadProfile() }
            .alert(
                "Couldn't update photo",
                isPresented: Binding(
                    get: { avatarUploadError != nil },
                    set: { if !$0 { avatarUploadError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(avatarUploadError ?? "")
            }
            .alert("Log out?", isPresented: $showLogoutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Log Out", role: .destructive) {
                    Haptics.success()
                    auth.signOut()
                    dismiss()
                }
            } message: {
                Text("You'll need to sign back in to access your decks.")
            }
            .alert("Delete account?", isPresented: $showDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Account", role: .destructive) {
                    Task { await performAccountDeletion() }
                }
            } message: {
                Text("This permanently deletes your decks, study history, XP, and profile. This can't be undone.")
            }
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackSheet(userName: profile?.onboarding?.name)
            }
            .sheet(item: $activeEditField) { field in
                if let onboarding = profile?.onboarding {
                    ProfileEditSheet(
                        field: field,
                        initialAnswers: onboarding,
                        onSaved: {
                            // Re-fetch so the profile body reflects the
                            // change as soon as the edit sheet closes.
                            Task { await loadProfile() }
                        }
                    )
                }
            }
            .alert(
                "Couldn't delete account",
                isPresented: Binding(
                    get: { deleteAccountError != nil },
                    set: { newValue in if !newValue { deleteAccountError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteAccountError ?? "")
            }
        }
    }

    // MARK: Pieces

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                avatarPicker
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text((profile?.onboarding?.name?.isEmpty == false ? profile!.onboarding!.name! : "Add your name"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.black)
                        Button {
                            Haptics.light()
                            activeEditField = .name
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let email = Auth.auth().currentUser?.email {
                        Text(email)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else if let uid = Auth.auth().currentUser?.uid {
                        Text(uid)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // Circular avatar that triggers a source-chooser (Take Selfie /
    // Choose from Library) and then UIImagePickerController with
    // `allowsEditing: true` for Apple's built-in square crop. Falls back
    // to a placeholder glyph when no image is saved yet. The camera
    // badge in the bottom-right is the tap affordance.
    private var avatarPicker: some View {
        Button {
            Haptics.light()
            showAvatarSourceChooser = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if isUploadingAvatar {
                        ZStack {
                            Circle().fill(Color(white: 0.9))
                            ProgressView().tint(.black)
                        }
                    } else if let data = profile?.avatarImage,
                              let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Circle().fill(Color(white: 0.9))
                            Image(systemName: "person.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color(white: 0.55))
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.black))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingAvatar)
        .confirmationDialog(
            "Update profile photo",
            isPresented: $showAvatarSourceChooser,
            titleVisibility: .visible
        ) {
            // The camera button only appears on devices with a camera —
            // simulator runs and iPads without a rear camera otherwise
            // get a button that silently no-ops.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Selfie") {
                    activeImagePickerSource = .camera
                }
            }
            Button("Choose from Library") {
                activeImagePickerSource = .photoLibrary
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $activeImagePickerSource) { source in
            ImagePicker(source: source) { picked in
                Task { await handlePickedImage(picked) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        editField: ProfileEditField? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let editField {
                    Button {
                        Haptics.light()
                        activeEditField = editField
                    } label: {
                        Text("Edit")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
    }

    private func emptyValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .italic()
    }

    @ViewBuilder
    private func interestsSection(onboarding: OnboardingAnswers) -> some View {
        let all = onboarding.interests ?? []
        section("Interests", editField: .interests) {
            if all.isEmpty {
                emptyValue("Tap Edit to choose what you're into.")
            } else {
                let visible = showAllInterests ? all : Array(all.prefix(collapsedInterestsCount))
                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6) {
                        ForEach(visible, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 13))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(white: 0.93)))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if all.count > collapsedInterestsCount {
                        Button {
                            Haptics.light()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showAllInterests.toggle()
                            }
                        } label: {
                            Text(showAllInterests ? "Show less" : "View more")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // Neutral primary action above the destructive ones. Outlined-on-
    // white styling distinguishes it from the red Log Out fill so the
    // hierarchy reads: positive action → sign-out → delete.
    private var feedbackButton: some View {
        Button {
            Haptics.light()
            showFeedbackSheet = true
        } label: {
            Text("Send Feedback")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .stroke(Color.black, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var logoutButton: some View {
        Button {
            Haptics.medium()
            showLogoutConfirm = true
        } label: {
            Text("Log Out")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.red)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Plain-text secondary action below the primary Log Out CTA — by
    // design less hit-prone than a filled button. The confirmation
    // alert then doubles as the actual safety gate.
    private var deleteAccountButton: some View {
        Button {
            Haptics.medium()
            showDeleteAccountConfirm = true
        } label: {
            Group {
                if isDeletingAccount {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.red)
                        Text("Deleting account…")
                    }
                } else {
                    Text("Delete account")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDeletingAccount)
    }

    @MainActor
    private func performAccountDeletion() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await auth.deleteAccount()
            Haptics.success()
            dismiss()
        } catch let error as NSError {
            // FIRAuthErrorCode.requiresRecentLogin == 17014. Firebase
            // gates `user.delete()` on a fresh sign-in for sensitive
            // actions; on this path the Firestore data was already
            // wiped, so we send the user to sign back in and try again.
            if error.domain == AuthErrorDomain,
               error.code == AuthErrorCode.requiresRecentLogin.rawValue {
                deleteAccountError = "Your data was removed, but Firebase needs a fresh sign-in to finish deleting your account. Tap Log Out, sign back in, then try Delete account again."
            } else {
                deleteAccountError = error.localizedDescription
            }
        }
    }

    // Called once the user finishes UIImagePickerController. The image
    // we receive has already been cropped to a square by the picker's
    // built-in editing UI; we only have to downscale + compress to keep
    // the Firestore payload small, then persist.
    @MainActor
    private func handlePickedImage(_ image: UIImage) async {
        isUploadingAvatar = true
        defer {
            isUploadingAvatar = false
            activeImagePickerSource = nil
        }
        guard let resized = image.tongues_downscaledJPEG(maxDimension: 256, quality: 0.8) else {
            avatarUploadError = "Couldn't process that image. Try another one."
            return
        }
        do {
            try await UserService.saveAvatarImage(resized)
            profile?.avatarImage = resized
            Haptics.success()
        } catch {
            avatarUploadError = error.localizedDescription
        }
    }

    @MainActor
    private func loadProfile() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await UserService.fetchProfile()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// Picker source for the profile-photo flow. Identifiable so the same
// @State enum can drive a `.sheet(item:)` and pass the source through
// to the UIImagePickerController wrapper without juggling two booleans.
enum ImagePickerSource: Identifiable {
    case camera
    case photoLibrary

    var id: String {
        switch self {
        case .camera: return "camera"
        case .photoLibrary: return "library"
        }
    }

    var uiKitValue: UIImagePickerController.SourceType {
        switch self {
        case .camera: return .camera
        case .photoLibrary: return .photoLibrary
        }
    }
}

// Thin SwiftUI wrapper around UIImagePickerController. `allowsEditing:
// true` enables Apple's built-in square crop screen after the user
// picks/takes a photo — that's the "Move and Scale" UI you see on iOS
// when setting a profile photo in Contacts. We prefer the edited image
// when present and fall back to the original otherwise.
struct ImagePicker: UIViewControllerRepresentable {
    let source: ImagePickerSource
    let onPicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = source.uiKitValue
        controller.allowsEditing = true
        if source == .camera {
            // Default to the front camera for the "take a selfie" CTA.
            // Falls through harmlessly on devices that don't have one.
            if UIImagePickerController.isCameraDeviceAvailable(.front) {
                controller.cameraDevice = .front
            }
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let image {
                parent.onPicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private extension UIImage {
    // Aspect-fit scale to `maxDimension` on the longest side, then encode
    // as JPEG at `quality`. Returns nil only if JPEG encoding fails. Used
    // by the profile avatar uploader to keep the stored payload small.
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
