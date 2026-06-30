import SwiftUI
import AVFoundation

// Pronunciation practice surface. Triggered from the "practice this"
// button on any assistant bubble. Inspired by the Jumpspeak / Pimsleur
// drill loop but layered with per-word coaching tips and an in-session
// attempt history so the user can SEE their score climb.
//
// Flow:
//   1. User opens sheet anchored to a specific target sentence.
//   2. Big mic button. Tap → STT starts. Speaker icon plays the native
//      reference audio if they want to hear it first.
//   3. Tap mic again → STT stops, transcript is shipped to Claude with
//      the target; comes back as a `PronunciationGrade`.
//   4. Sheet renders a colored word strip (good/shaky/off/missing),
//      overall score, and a coaching tip. Tap any word to expand its
//      hint.
//   5. "Try again" resets the drill state for another pass; previous
//      attempts surface as small score chips so improvement is
//      visible.
struct PronunciationDrillSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: String
    // Phonetic guide rendered below the target sentence. Optional —
    // most messages carry a transliteration but a few (e.g. words that
    // are already Latinized) skip it.
    let transliteration: String?
    let language: String
    let dialect: String

    @State private var speech = SpeechRecognitionService.shared
    @State private var grade: ConversationClient.PronunciationGrade?
    @State private var attempts: [ConversationClient.PronunciationGrade] = []
    @State private var savedAttempts: [PronunciationAttempt] = []
    @State private var isGrading = false
    @State private var errorText: String?
    @State private var expandedWordID: UUID?
    @State private var attemptPlayer: AVAudioPlayer?
    @State private var isPlayingBack = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    targetCard
                    micCluster
                    if let grade {
                        gradeBlock(grade)
                    }
                    if attempts.count > 1 {
                        attemptHistory
                    }
                    if !savedAttempts.isEmpty {
                        pastAttemptHistory
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        speech.stop()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        SpeechClient.shared.speak(
                            target,
                            language: language,
                            allowForvo: false
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2")
                            Text("Listen")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .alert("Couldn't grade attempt", isPresented: errorAlertBinding) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task {
                await loadSavedAttempts()
            }
            .onDisappear {
                speech.stop()
                speech.onSilenceDetected = nil
                attemptPlayer?.stop()
                attemptPlayer = nil
                isPlayingBack = false
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read it aloud")
                .font(.custom("PlayfairDisplay-Regular", size: 24))
                .tracking(-1.2)
                .foregroundStyle(.white)
            Text("Tap the mic, say the sentence in \(language), tap again to grade. Your past scores show below as you go.")
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let grade {
                FlowLayout(spacing: 6) {
                    ForEach(grade.words) { score in
                        wordChip(score)
                    }
                }
            } else {
                Text(target)
                    .font(.custom("NeueHaasDisplay-Roman", size: 20))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let transliteration, !transliteration.isEmpty {
                Text(transliteration)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .italic()
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func wordChip(_ score: ConversationClient.WordScore) -> some View {
        let tint = color(for: score.grade)
        return Button {
            Haptics.light()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                expandedWordID = expandedWordID == score.id ? nil : score.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(score.expected)
                    .font(.custom("NeueHaasDisplay-Roman", size: 18))
                    .foregroundStyle(score.grade == .missing ? Color.white.opacity(0.5) : .white)
                    .strikethrough(score.grade == .missing)
                if expandedWordID == score.id,
                   let hint = score.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.55))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(score.hint == nil)
    }

    private var micCluster: some View {
        VStack(spacing: 12) {
            Button {
                Task { await toggleMic() }
            } label: {
                ZStack {
                    Circle()
                        .fill(speech.isRecording ? Color.red : Color.white)
                        .frame(width: 84, height: 84)
                    if isGrading {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.black)
                    } else {
                        Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(speech.isRecording ? .white : .black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isGrading)

            Text(micStatus)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.6))

            if speech.isRecording && !speech.transcript.isEmpty {
                Text(speech.transcript)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .italic()
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var micStatus: String {
        if isGrading { return "Grading your attempt…" }
        if speech.isRecording { return "Listening — tap to stop" }
        if grade != nil { return "Tap to try again" }
        return "Tap to start"
    }

    private func gradeBlock(_ grade: ConversationClient.PronunciationGrade) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(grade.overallScore)")
                    .font(.custom("NeueHaasDisplay-Mediu", size: 60))
                    .foregroundStyle(scoreColor(grade.overallScore))
                Text("/ 100")
                    .font(.custom("NeueHaasDisplay-Light", size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            Text(grade.coachingTip)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 8) {
                Button {
                    Haptics.light()
                    SpeechClient.shared.speak(
                        target,
                        language: language,
                        allowForvo: false
                    )
                } label: {
                    Label("Hear native", systemImage: "speaker.wave.2")
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)

                if speech.lastRecordingURL != nil {
                    Button {
                        Haptics.light()
                        toggleAttemptPlayback()
                    } label: {
                        Label(
                            isPlayingBack ? "Stop" : "Hear yourself",
                            systemImage: isPlayingBack ? "stop.fill" : "person.wave.2"
                        )
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.4))
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Haptics.medium()
                    self.grade = nil
                    speech.transcript = ""
                    expandedWordID = nil
                    attemptPlayer?.stop()
                    attemptPlayer = nil
                    isPlayingBack = false
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    // Past attempts persisted to Firestore, filtered to the same
    // target sentence so the user sees their progression on THIS
    // phrase. Capped at 6 for layout; older ones live in the DB but
    // don't crowd the sheet.
    private var pastAttemptHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAST ATTEMPTS ON THIS PHRASE")
                .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 6) {
                ForEach(savedAttempts.prefix(6)) { attempt in
                    Text("\(attempt.grade.overallScore)")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(scoreColor(attempt.grade.overallScore))
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
    }

    private var attemptHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS SESSION")
                .font(.custom("NeueHaasDisplay-Mediu", size: 11))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 8) {
                ForEach(Array(attempts.enumerated()), id: \.offset) { idx, attempt in
                    Text("\(attempt.overallScore)")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(scoreColor(attempt.overallScore))
                        .clipShape(Capsule())
                        .opacity(idx == attempts.count - 1 ? 1.0 : 0.6)
                }
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func toggleMic() async {
        if speech.isRecording {
            await finishRecordingAndGrade()
            return
        }
        let status = SpeechRecognitionService.currentAuthorization()
        if status == .undetermined {
            let granted = await SpeechRecognitionService.requestAuthorization()
            if granted != .authorized { return }
        } else if status != .authorized {
            errorText = "Enable speech recognition in Settings to use practice mode."
            return
        }
        let locale = appleSpeechLocale(for: language) ?? "en-US"
        // Wire silence-detection BEFORE start so the engine's first
        // few buffers can already trip it if needed.
        speech.onSilenceDetected = {
            Haptics.light()
            Task { await finishRecordingAndGrade() }
        }
        do {
            // Longer silence window than the conversation auto-mic so a
            // mid-sentence pause or breath doesn't stop the recording
            // before the learner finishes the whole sentence.
            try speech.start(locale: locale, silenceTimeout: 3.0)
            Haptics.medium()
            grade = nil
            expandedWordID = nil
            attemptPlayer?.stop()
            attemptPlayer = nil
            isPlayingBack = false
        } catch {
            errorText = error.localizedDescription
            speech.onSilenceDetected = nil
        }
    }

    // Stops the engine and runs the captured transcript through Claude.
    // Shared between the manual-tap path and the auto-silence path.
    private func finishRecordingAndGrade() async {
        speech.onSilenceDetected = nil
        speech.stop()
        let attempt = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attempt.isEmpty else { return }
        await runGrade(attempt: attempt)
    }

    private func runGrade(attempt: String) async {
        isGrading = true
        defer { isGrading = false }
        do {
            let result = try await ConversationClient.gradePronunciation(
                target: target,
                attempted: attempt,
                language: language,
                dialect: dialect
            )
            Haptics.success()
            grade = result
            attempts.append(result)
            await persistAttempt(transcript: attempt, grade: result)
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private func persistAttempt(
        transcript: String,
        grade: ConversationClient.PronunciationGrade
    ) async {
        let stored = PronunciationAttempt(
            language: language,
            languageID: Conversation.languageID(for: language),
            dialect: dialect,
            target: target,
            transcript: transcript,
            grade: grade
        )
        do {
            try await FirebasePronunciationService.save(stored)
            // Prepend so the new attempt appears first in the
            // persisted strip without a full re-fetch.
            savedAttempts.insert(stored, at: 0)
        } catch {
            // Non-fatal — the in-session view still works.
            print("Pronunciation save failed: \(error)")
        }
    }

    // Plays back the captured audio of the most recent attempt so the
    // user can hear what they actually sounded like.
    private func toggleAttemptPlayback() {
        if isPlayingBack {
            attemptPlayer?.stop()
            attemptPlayer = nil
            isPlayingBack = false
            return
        }
        guard let url = speech.lastRecordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            // Light auto-stop when playback finishes; AVAudioPlayer
            // doesn't expose Combine completion so we poll for it on
            // a short MainActor timer.
            player.play()
            attemptPlayer = player
            isPlayingBack = true
            Task { @MainActor in
                while let p = attemptPlayer, p.isPlaying {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                isPlayingBack = false
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadSavedAttempts() async {
        do {
            let recent = try await FirebasePronunciationService.recent(
                languageID: Conversation.languageID(for: language),
                limit: 50
            )
            // Filter to the specific target so the strip reads as
            // "how have I done on this exact phrase before?". Older
            // attempts for other sentences stay in Firestore but
            // don't clutter this drill.
            savedAttempts = recent.filter { $0.target == target }
        } catch {
            savedAttempts = []
        }
    }

    private func color(for mark: ConversationClient.WordScore.Mark) -> Color {
        switch mark {
        case .good:    return Color(red: 0.18, green: 0.55, blue: 0.30)
        case .shaky:   return Color(red: 0.78, green: 0.55, blue: 0.10)
        case .off:     return Color(red: 0.78, green: 0.22, blue: 0.20)
        case .missing: return Color.gray
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...:    return Color(red: 0.18, green: 0.55, blue: 0.30)
        case 60...:    return Color(red: 0.78, green: 0.55, blue: 0.10)
        default:       return Color(red: 0.78, green: 0.22, blue: 0.20)
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }
}
