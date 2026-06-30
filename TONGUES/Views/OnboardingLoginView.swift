import SwiftUI
import AuthenticationServices

struct OnboardingLoginView: View {
    let onboardingAnswers: OnboardingAnswers
    let onComplete: () -> Void
    var isSignIn: Bool = false  // True = returning user (skip onboarding save to avoid clobbering)
    // Starter-deck titles from the final onboarding page, auto-generated
    // into the library after a new sign-up so Study is never empty.
    var sampleDeckTitles: [String] = []

    @State private var auth = AuthService.shared
    @State private var isWorking = false
    @State private var showEmailSheet = false
    @State private var showPhoneSheet = false
    // Surfaced when `UserService.saveOnboarding` throws after a
    // successful sign-in. Previously silenced via `print`, which let
    // users enter the app without their answers persisted and with no
    // signal that anything had gone wrong.
    @State private var onboardingSaveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Text(isSignIn ? "Welcome back" : "Almost there")
                    .font(.custom("PlayfairDisplay-Regular", size: 36))
                    .tracking(-2.88)
                    .foregroundStyle(.black)

                Text(isSignIn
                     ? "Sign in to pick up where you left off."
                     : "Sign in to save your decks and progress.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                // Primary: Apple — native SwiftUI button, Apple HIG compliant
                SignInWithAppleButton(.signIn) { request in
                    Haptics.medium()
                    auth.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task {
                        await auth.completeAppleSignIn(result)
                        await finishIfAuthenticated()
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(Capsule())

                // Secondary: Google
                Button {
                    Task {
                        Haptics.medium()
                        isWorking = true
                        await auth.signInWithGoogle()
                        isWorking = false
                        await finishIfAuthenticated()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 17))
                        Text("Continue with Google")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .overlay(Capsule().stroke(Color(white: 0.85)))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                // Divider
                HStack(spacing: 12) {
                    Rectangle().fill(Color(white: 0.85)).frame(height: 1)
                    Text("or")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Rectangle().fill(Color(white: 0.85)).frame(height: 1)
                }
                .padding(.vertical, 4)

                tertiaryButton(title: "Continue with Phone", systemImage: "phone.fill") {
                    Haptics.light()
                    showPhoneSheet = true
                }

                tertiaryButton(title: "Continue with Email", systemImage: "envelope.fill") {
                    Haptics.light()
                    showEmailSheet = true
                }
            }
            .padding(.horizontal, 24)

            if let error = auth.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }

            // Markdown link parsing: SwiftUI's Text picks up the inline
            // `[Terms of Service](url)` / `[Privacy Policy](url)` markup
            // and turns each into a tappable Link with the environment's
            // accent color. Both point at the canonical mytongues.com
            // legal pages.
            Text("By continuing, you agree to our [Terms of Service](https://www.mytongues.com/terms.html) and [Privacy Policy](https://www.mytongues.com/privacy.html).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEmailSheet) {
            EmailAuthSheet(initialMode: isSignIn ? .signIn : .signUp) {
                Task { await finishIfAuthenticated() }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPhoneSheet) {
            PhoneAuthSheet {
                Task { await finishIfAuthenticated() }
            }
            .presentationDetents([.medium, .large])
        }
        .alert(
            "Couldn't save your answers",
            isPresented: saveErrorBinding,
            presenting: onboardingSaveError
        ) { _ in
            Button("Try again") {
                onboardingSaveError = nil
                Task { await finishIfAuthenticated() }
            }
            Button("Continue anyway", role: .cancel) {
                // User explicitly chose to enter the app without
                // persisted onboarding — clear the error and proceed.
                onboardingSaveError = nil
                onComplete()
            }
        } message: { message in
            Text("We hit a problem saving your onboarding answers: \(message)\n\nYou can retry, or continue into the app — you may need to set your language preferences manually.")
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { onboardingSaveError != nil },
            set: { if !$0 { onboardingSaveError = nil } }
        )
    }

    @MainActor
    private func finishIfAuthenticated() async {
        guard auth.isAuthenticated else { return }
        if !isSignIn {
            do {
                try await UserService.saveOnboarding(onboardingAnswers)
            } catch {
                // Surface the failure to the user rather than dropping
                // it on the floor — without this they'd enter the app
                // with no record of their answers and no idea anything
                // had gone wrong. The alert offers Retry + Continue.
                Haptics.error()
                onboardingSaveError = error.localizedDescription
                return
            }
            // Auto-generate the suggested starter decks (free, no paywall)
            // in the background so the Study tab has content immediately.
            OnboardingDeckSeeder.shared.seed(
                answers: onboardingAnswers,
                titles: sampleDeckTitles
            )
        }
        Haptics.success()
        onComplete()
    }



    private func tertiaryButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white)
            .overlay(Capsule().stroke(Color(white: 0.85)))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Inline sheet that owns the email + password fields and the toggle
// between sign-in and create-account modes. Calls back into the parent
// via `onSuccess` once Firebase returns an authenticated user so the
// parent can save onboarding answers + dismiss.
struct EmailAuthSheet: View {
    enum Mode { case signIn, signUp }

    let initialMode: Mode
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthService.shared
    @State private var mode: Mode
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isWorking = false
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    init(initialMode: Mode, onSuccess: @escaping () -> Void) {
        self.initialMode = initialMode
        self.onSuccess = onSuccess
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Mode", selection: $mode) {
                    Text("Sign In").tag(Mode.signIn)
                    Text("Create Account").tag(Mode.signUp)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                        .padding(14)
                        .overlay(Capsule().stroke(Color(white: 0.85)))

                    SecureField("Password", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { Task { await submit() } }
                        .padding(14)
                        .overlay(Capsule().stroke(Color(white: 0.85)))
                }

                if let error = auth.lastError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Text(mode == .signIn ? "Sign In" : "Create Account")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canSubmit ? Color.black : Color.black.opacity(0.35))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .navigationTitle(mode == .signIn ? "Sign In" : "Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        auth.lastError = nil
                        dismiss()
                    }
                    .tint(.black)
                }
            }
            .onAppear {
                auth.lastError = nil
                focusedField = .email
            }
            .onChange(of: mode) { _, _ in
                // Clear the prior error when the user flips between
                // Sign In and Create Account so the old message doesn't
                // sit there contradicting the new mode.
                auth.lastError = nil
            }
        }
    }

    private var canSubmit: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        return trimmedEmail.contains("@") && password.count >= 6
    }

    @MainActor
    private func submit() async {
        guard canSubmit, !isWorking else { return }
        Haptics.medium()
        isWorking = true
        defer { isWorking = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let success: Bool
        switch mode {
        case .signIn:
            success = await auth.signInWithEmail(trimmedEmail, password: password)
        case .signUp:
            success = await auth.createUserWithEmail(trimmedEmail, password: password)
        }
        if success {
            Haptics.success()
            onSuccess()
            dismiss()
        }
    }
}

// Phone-number sign-in. Two-step: collect an E.164 phone number, ask
// Firebase to send an SMS code, then verify. Works the same for new
// and returning users — Firebase creates the account on first verify
// and signs the existing one in on subsequent verifies.
struct PhoneAuthSheet: View {
    enum Step { case phone, code }

    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthService.shared
    @State private var step: Step = .phone
    @State private var phoneNumber: String = ""
    @State private var code: String = ""
    @State private var verificationID: String?
    @State private var isWorking = false
    @FocusState private var focusedField: Field?

    enum Field { case phone, code }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(step == .phone ? "Enter your phone number" : "Enter the code we sent")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if step == .phone {
                    TextField("+1 555 123 4567", text: $phoneNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .submitLabel(.send)
                        .focused($focusedField, equals: .phone)
                        .onSubmit { Task { await requestCode() } }
                        .padding(14)
                        .overlay(Capsule().stroke(Color(white: 0.85)))
                } else {
                    Text(phoneNumber)
                        .font(.system(size: 15))
                        .foregroundStyle(.black)
                    TextField("123456", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .code)
                        .onSubmit { Task { await verifyCode() } }
                        .padding(14)
                        .overlay(Capsule().stroke(Color(white: 0.85)))
                    Button("Use a different number") {
                        auth.lastError = nil
                        code = ""
                        verificationID = nil
                        step = .phone
                        focusedField = .phone
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }

                if let error = auth.lastError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    Task {
                        if step == .phone {
                            await requestCode()
                        } else {
                            await verifyCode()
                        }
                    }
                } label: {
                    Group {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Text(step == .phone ? "Send code" : "Verify")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canSubmit ? Color.black : Color.black.opacity(0.35))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .navigationTitle("Sign in with phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        auth.lastError = nil
                        dismiss()
                    }
                    .tint(.black)
                }
            }
            .onAppear {
                auth.lastError = nil
                focusedField = step == .phone ? .phone : .code
            }
        }
    }

    private var canSubmit: Bool {
        switch step {
        case .phone:
            // Require at least a country code prefix + 6 digits. Firebase
            // expects E.164 (e.g. "+15551234567") but we accept formatted
            // input and let the user retype if Firebase rejects it.
            let stripped = phoneNumber
                .components(separatedBy: CharacterSet(charactersIn: "0123456789+").inverted)
                .joined()
            return stripped.hasPrefix("+") && stripped.count >= 8
        case .code:
            let digits = code.filter(\.isNumber)
            return digits.count == 6
        }
    }

    @MainActor
    private func requestCode() async {
        guard canSubmit, !isWorking else { return }
        Haptics.medium()
        isWorking = true
        defer { isWorking = false }
        let stripped = phoneNumber
            .components(separatedBy: CharacterSet(charactersIn: "0123456789+").inverted)
            .joined()
        if let id = await auth.sendPhoneVerification(to: stripped) {
            verificationID = id
            step = .code
            focusedField = .code
            Haptics.light()
        }
    }

    @MainActor
    private func verifyCode() async {
        guard canSubmit, !isWorking, let verificationID else { return }
        Haptics.medium()
        isWorking = true
        defer { isWorking = false }
        let digits = code.filter(\.isNumber)
        let success = await auth.signInWithPhone(
            verificationID: verificationID,
            code: digits
        )
        if success {
            Haptics.success()
            onSuccess()
            dismiss()
        }
    }
}
