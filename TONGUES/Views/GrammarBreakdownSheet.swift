import SwiftUI

// Dynamic grammatical breakdown of a single sentence — presented from the
// conversation bubble's "Grammar" action. Visual language matches the
// WordInfoSheet / Etymology modals: black background, white type, the
// explanation split into easily readable chunk cards.
struct GrammarBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sentence: String
    let language: String
    let dialect: String

    @State private var breakdown: GrammarBreakdown?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            rootContent
                .toolbar(.hidden, for: .navigationBar)
        }
        .presentationBackground(.black)
        .task { await loadIfNeeded() }
    }

    private var rootContent: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(sentence)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 40)

                    if let breakdown {
                        Text(breakdown.translation)
                            .font(.custom("NeueHaasDisplay-Light", size: 16))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))

                    Text("GRAMMATICAL BREAKDOWN")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.55))

                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Analyzing the grammar…")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let breakdown {
                        content(breakdown)
                    } else if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 40)
            }

            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func content(_ breakdown: GrammarBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            // Big-picture overview + classification chips.
            VStack(alignment: .leading, spacing: 14) {
                Text(breakdown.summary)
                    .font(.custom("NeueHaasDisplay-Light", size: 17))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    tag(breakdown.sentenceType)
                    tag(breakdown.register)
                }
            }

            // Sentence, piece by piece.
            if !breakdown.chunks.isEmpty {
                section("PIECE BY PIECE") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(breakdown.chunks) { chunk in
                            chunkCard(chunk)
                        }
                    }
                }
            }

            // Key grammar concepts.
            if !breakdown.grammarPoints.isEmpty {
                section("KEY GRAMMAR POINTS") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(breakdown.grammarPoints) { point in
                            pointCard(point)
                        }
                    }
                }
            }

            // Optional word-order note.
            if let note = breakdown.wordOrderNote, !note.isEmpty {
                section("WORD ORDER") {
                    Text(note)
                        .font(.custom("NeueHaasDisplay-Light", size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Cards

    private func chunkCard(_ chunk: GrammarBreakdown.Chunk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chunk.role.uppercased())
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(chunk.text)
                    .font(.custom("NeueHaasDisplay-Roman", size: 20))
                    .foregroundStyle(.white)
                if let translit = chunk.transliteration, !translit.isEmpty {
                    Text(translit)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .italic()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Text(chunk.literal)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Text(chunk.explanation)
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pointCard(_ point: GrammarBreakdown.GrammarPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(point.title)
                .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(point.explanation)
                .font(.custom("NeueHaasDisplay-Light", size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if let example = point.example, !example.isEmpty {
                Text(example)
                    .font(.custom("NeueHaasDisplay-Light", size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Bits

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.55))
            content()
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.custom("NeueHaasDisplay-Light", size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Load

    @MainActor
    private func loadIfNeeded() async {
        guard breakdown == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            breakdown = try await DeckGenerator.generateGrammarBreakdown(
                sentence: sentence,
                language: language,
                dialect: dialect,
                explanationLanguage: Self.userExplanationLanguage
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Device's preferred language → human-readable English name handed to
    // the prompt (mirrors WordInfoSheet's etymology helper).
    private static var userExplanationLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
