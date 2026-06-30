import SwiftUI

// Presented from ProfileView. Sits on a white card with a single
// multiline text editor and a black primary CTA — matches the existing
// onboarding / profile design language. Sends to the `feedback`
// Firestore collection via FeedbackService.
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Used to attribute the feedback when the user has a name on file.
    let userName: String?

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var errorMessage: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tell us what's on your mind — bugs, ideas, things you'd love to see. We read every note.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                // TextEditor wrapped in a softly-filled card so the
                // input field reads as a Profile-page section block
                // rather than a system form row.
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type your feedback…")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(white: 0.55))
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .focused($isEditorFocused)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.96))
                )
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 20)

                submitButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
            .alert(
                "Couldn't send feedback",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { newValue in if !newValue { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { isEditorFocused = true }
        }
    }

    // Primary CTA. Black-fill capsule matches Log Out's footprint so the
    // sheet's bottom action sits at the same height/weight as the
    // ProfileView's primary actions.
    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                } else if didSubmit {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("Sent")
                    }
                } else {
                    Text("Send Feedback")
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canSubmit && !didSubmit ? Color.black : Color.black.opacity(0.35))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isSubmitting || didSubmit)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await FeedbackService.submit(text: text, userName: userName)
            Haptics.success()
            // Brief confirmation state before dismissing so the user
            // can see the send landed — keeps the moment grounded.
            didSubmit = true
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
