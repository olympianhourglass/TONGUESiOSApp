import SwiftUI
import FirebaseAuth
import UIKit

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthService.shared
    @State private var subscription = SubscriptionService.shared
    @State private var showPaywall = false
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showLogoutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showFeedbackSheet = false
    @State private var activeEditField: ProfileEditField?
    @State private var showAvatarSourceChooser = false
    @State private var activeImagePickerSource: ImagePickerSource?
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String?
    // App (native) language control.
    @State private var localizer = Localizer.shared
    @State private var showNativeLanguagePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountHeader
                        .padding(.top, 8)

                    NavigationLink {
                        SavedInsightsView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.black)
                            Text(L("View Saved Insights"))
                                .font(.system(size: 16))
                                .foregroundStyle(.black)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    settingsLinkRow(
                        icon: "chart.bar",
                        title: L("Usage"),
                        summary: nil
                    ) { usageDetail }

                    settingsLinkRow(
                        icon: "square.grid.2x2",
                        title: L("Widgets"),
                        summary: nil
                    ) { widgetsDetail }

                    // App language is independent of onboarding, so it shows
                    // even before the profile loads.
                    settingsLinkRow(
                        icon: "globe",
                        title: L("Native Language"),
                        summary: localizer.language.endonym
                    ) { appLanguageDetail }

                    if let onboarding = profile?.onboarding {
                        settingsLinkRow(
                            icon: "text.bubble",
                            title: L("Languages"),
                            summary: languagesSummary(onboarding)
                        ) { languagesDetail }

                        settingsLinkRow(
                            icon: "airplane",
                            title: L("Travel destinations"),
                            summary: destinationsSummary(onboarding)
                        ) { destinationsDetail }

                        settingsLinkRow(
                            icon: "sparkles",
                            title: L("What you'd love to understand"),
                            summary: understandSummary(onboarding)
                        ) { understandDetail }

                        settingsLinkRow(
                            icon: "heart",
                            title: L("Interests"),
                            summary: interestsSummary(onboarding)
                        ) { interestsDetail }
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
            .navigationTitle(L("Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                        .tint(.black)
                }
            }
            .task { await loadProfile() }
            .task { await subscription.refresh() }
            .alert(
                L("Couldn't update photo"),
                isPresented: Binding(
                    get: { avatarUploadError != nil },
                    set: { if !$0 { avatarUploadError = nil } }
                )
            ) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(avatarUploadError ?? "")
            }
            .alert(L("Log out?"), isPresented: $showLogoutConfirm) {
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Log Out"), role: .destructive) {
                    Haptics.success()
                    auth.signOut()
                    dismiss()
                }
            } message: {
                Text(L("You'll need to sign back in to access your decks."))
            }
            .alert(L("Delete account?"), isPresented: $showDeleteAccountConfirm) {
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Delete Account"), role: .destructive) {
                    Task { await performAccountDeletion() }
                }
            } message: {
                Text(L("This permanently deletes your decks, study history, XP, and profile. This can't be undone."))
            }
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackSheet(userName: profile?.onboarding?.name)
            }
            .sheet(isPresented: $showPaywall) {
                PremiumActionSheet()
            }
            .sheet(isPresented: $showNativeLanguagePicker) {
                NativeLanguagePickerSheet()
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
                L("Couldn't delete account"),
                isPresented: Binding(
                    get: { deleteAccountError != nil },
                    set: { newValue in if !newValue { deleteAccountError = nil } }
                )
            ) {
                Button(L("OK"), role: .cancel) {}
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
                        Text((profile?.onboarding?.name?.isEmpty == false ? profile!.onboarding!.name! : L("Add your name")))
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
                    subscriptionPlanRow
                }
                Spacer(minLength: 0)
            }
        }
    }

    // Current plan, one line under the email. Tapping opens the paywall so
    // the user can change plans from here.
    private var subscriptionPlanRow: some View {
        Button {
            Haptics.light()
            showPaywall = true
        } label: {
            HStack(spacing: 4) {
                Text(L("%@ plan", subscription.currentTier.displayName))
                    .font(.system(size: 13))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            L("Update profile photo"),
            isPresented: $showAvatarSourceChooser,
            titleVisibility: .visible
        ) {
            // The camera button only appears on devices with a camera —
            // simulator runs and iPads without a rear camera otherwise
            // get a button that silently no-ops.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(L("Take Selfie")) {
                    activeImagePickerSource = .camera
                }
            }
            Button(L("Choose from Library")) {
                activeImagePickerSource = .photoLibrary
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .sheet(item: $activeImagePickerSource) { source in
            ImagePicker(source: source) { picked in
                Task { await handlePickedImage(picked) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Settings rows + detail views

    // A tappable settings row that pushes a detail view, replacing the old
    // always-expanded sections. The optional trailing summary previews the
    // value so the collapsed list still reads at a glance.
    @ViewBuilder
    private func settingsLinkRow<Destination: View>(
        icon: String,
        title: String,
        summary: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Shared chrome for a settings detail screen: scrollable content with an
    // optional trailing Edit/Change action in the nav bar. The action reuses
    // the existing edit sheets presented from the Profile root, so edits still
    // flow through `activeEditField` / `showNativeLanguagePicker`. Read-only
    // details (Usage, Widgets) pass no action and get no toolbar button.
    @ViewBuilder
    private func settingsDetail<Content: View>(
        title: String,
        editLabel: String? = nil,
        onEdit: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let editLabel, let onEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editLabel) {
                        Haptics.light()
                        onEdit()
                    }
                    .tint(.black)
                }
            }
        }
    }

    private var appLanguageDetail: some View {
        settingsDetail(
            title: L("Native Language"),
            editLabel: L("Change"),
            onEdit: { showNativeLanguagePicker = true }
        ) {
            HStack(spacing: 8) {
                Text(localizer.language.flag)
                    .font(.system(size: 22))
                Text(localizer.language.endonym)
                    .font(.system(size: 16))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.93)))
            .fixedSize(horizontal: true, vertical: false)

            Text(L("The language TONGUES' interface is shown in."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var languagesDetail: some View {
        settingsDetail(
            title: L("Languages"),
            editLabel: L("Edit"),
            onEdit: { activeEditField = .languages }
        ) {
            let prefs = profile?.onboarding?.languagePreferences ?? []
            if prefs.isEmpty {
                emptyValue(L("No languages on file yet."))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(prefs) { pref in
                        Text("\(localizedLanguageName(pref.language)) · \(L(pref.dialect)) · \(L(pref.level))")
                            .font(.system(size: 15))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(white: 0.93)))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private var destinationsDetail: some View {
        settingsDetail(
            title: L("Travel destinations"),
            editLabel: L("Edit"),
            onEdit: { activeEditField = .destinations }
        ) {
            let destinations = profile?.onboarding?.destinations ?? []
            if destinations.isEmpty {
                emptyValue(L("No destinations on file yet."))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(destinations) { dest in
                        Text("· \(dest.name)")
                            .font(.system(size: 15))
                            .foregroundStyle(.black)
                    }
                }
            }
        }
    }

    private var understandDetail: some View {
        settingsDetail(
            title: L("What you'd love to understand"),
            editLabel: L("Edit"),
            onEdit: { activeEditField = .understand }
        ) {
            if let understand = profile?.onboarding?.firstUnderstand, !understand.isEmpty {
                Text(understand)
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
            } else {
                emptyValue(L("Tap Edit to pick one."))
            }
        }
    }

    private var interestsDetail: some View {
        settingsDetail(
            title: L("Interests"),
            editLabel: L("Edit"),
            onEdit: { activeEditField = .interests }
        ) {
            let all = profile?.onboarding?.interests ?? []
            if all.isEmpty {
                emptyValue(L("Tap Edit to choose what you're into."))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(all, id: \.self) { chip in
                        Text(L(chip))
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
    }

    // MARK: Settings row summaries

    private func languagesSummary(_ onboarding: OnboardingAnswers) -> String {
        let prefs = onboarding.languagePreferences ?? []
        guard let first = prefs.first else { return "" }
        let name = localizedLanguageName(first.language)
        return prefs.count > 1 ? "\(name) +\(prefs.count - 1)" : name
    }

    private func destinationsSummary(_ onboarding: OnboardingAnswers) -> String {
        let destinations = onboarding.destinations ?? []
        guard let first = destinations.first else { return "" }
        return destinations.count > 1 ? "\(first.name) +\(destinations.count - 1)" : first.name
    }

    private func understandSummary(_ onboarding: OnboardingAnswers) -> String {
        onboarding.firstUnderstand ?? ""
    }

    private func interestsSummary(_ onboarding: OnboardingAnswers) -> String {
        let count = (onboarding.interests ?? []).count
        return count == 0 ? "" : L("%d", count)
    }

    // "Usage" — this month's consumption of each metered bucket against the
    // current tier's cap, mirroring the limits shown on the paywall. Reads
    // straight off SubscriptionService (refreshed in .task above).
    private var usageDetail: some View {
        settingsDetail(title: L("Usage")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SubscriptionBucket.allCases, id: \.self) { bucket in
                    usageRow(bucket)
                }
                Text(L("This month · resets on the 1st"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // Both home-screen and lock-screen widget configurators, tucked behind a
    // settings row so they no longer stretch the Profile scroll view.
    private var widgetsDetail: some View {
        settingsDetail(title: L("Widgets")) {
            WordCycleWidgetSection()
            LockScreenWidgetSection()
        }
    }

    @ViewBuilder
    private func usageRow(_ bucket: SubscriptionBucket) -> some View {
        let cap = bucket.cap(for: subscription.currentTier)
        let used = subscription.state.usage(in: bucket, monthKey: subscription.currentMonthKey)
        let isFinite = cap > 0 && cap != Int.max
        let fraction = isFinite ? min(1, Double(used) / Double(cap)) : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(bucket.titleLabel))
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
                Spacer()
                Text(usageValueText(used: used, cap: cap))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if isFinite {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.08))
                        Capsule()
                            .fill(fraction >= 1 ? Color.red : Color.black)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    // "used of total", where the total is the current tier's cap. Free
    // (0-cap) buckets read "Not included"; unlimited tiers show ∞.
    private func usageValueText(used: Int, cap: Int) -> String {
        if cap == 0 { return L("Not included") }
        if cap == Int.max { return L("%d of ∞", used) }
        return L("%d of %d", used, cap)
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
                        Text(L("Edit"))
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

    // Neutral primary action above the destructive ones. Outlined-on-
    // white styling distinguishes it from the red Log Out fill so the
    // hierarchy reads: positive action → sign-out → delete.
    private var feedbackButton: some View {
        Button {
            Haptics.light()
            showFeedbackSheet = true
        } label: {
            Text(L("Send Feedback"))
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
            Text(L("Log Out"))
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
                        Text(L("Deleting account…"))
                    }
                } else {
                    Text(L("Delete account"))
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
                deleteAccountError = L("Your data was removed, but Firebase needs a fresh sign-in to finish deleting your account. Tap Log Out, sign back in, then try Delete account again.")
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
            avatarUploadError = L("Couldn't process that image. Try another one.")
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

// App-language picker presented from the profile's "App language" section.
// Selecting a row flips the app-wide UI language immediately (Localizer is
// @Observable) and persists it; styled to match the app's list sheets.
private struct NativeLanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var localizer = Localizer.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        Haptics.light()
                        Localizer.shared.language = lang
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text(lang.flag)
                                .font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lang.endonym)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.black)
                                Text(lang.englishName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if localizer.language == lang {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle(L("App language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                        .tint(.black)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
