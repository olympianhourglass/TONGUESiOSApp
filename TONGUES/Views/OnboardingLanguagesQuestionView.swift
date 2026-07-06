import SwiftUI

struct OnboardingLanguagesQuestionView: View {
    let questionNumber: Int
    let totalQuestions: Int
    @Bindable var state: OnboardingState
    let onNext: () -> Void
    var showsProgress: Bool = true
    // nil keeps the onboarding "Next" label; settings edit passes "Save".
    var ctaTitle: String? = nil

    @State private var activeEdit: EditTarget?
    @State private var suggestedLanguages: [LanguagePreference] = []
    @State private var isLoadingSuggestions = false
    @State private var hasFetchedSuggestions = false

    private struct EditTarget: Identifiable {
        let index: Int
        let attribute: DeckAttribute
        var id: String { "\(index)-\(attribute.rawValue)" }
    }

    @State private var subscription = SubscriptionService.shared
    @State private var capError: SubscriptionError?

    // Per-tier ceiling. Free/Beginner/Pro share a 3-language cap;
    // Max returns Int.max for "unlimited". Driven by the live tier
    // so a mid-onboarding sign-in + purchase lifts the cap
    // immediately.
    private var maxLanguages: Int {
        subscription.currentTier.maxLanguages
    }

    private var languageCapCopy: String {
        let max = maxLanguages
        if max == Int.max { return "Pick as many as you'd like. Drag to reorder by priority." }
        return "Pick up to \(max). Drag to reorder by priority."
    }

    private var visibleSuggestions: [LanguagePreference] {
        let existing = Set(state.languagePreferences.map { $0.language })
        return suggestedLanguages.filter { !existing.contains($0.language) }
    }

    // Returns true when appending another language would exceed the
    // tier cap. Used to flip the Add / suggestion buttons into the
    // paywall-presenting branch instead of the append branch.
    private var atLanguageCap: Bool {
        state.languagePreferences.count >= maxLanguages
    }

    // Called from every "add a language" path. Shows the paywall
    // alert when over cap; otherwise runs the supplied append.
    private func addLanguage(_ append: () -> Void) {
        if atLanguageCap {
            capError = .languageCapExceeded(
                tier: subscription.currentTier,
                max: maxLanguages
            )
            return
        }
        append()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsProgress {
                ProgressView(value: Double(questionNumber), total: Double(totalQuestions))
                    .progressViewStyle(.linear)
                    .tint(.black)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Text("\(questionNumber) of \(totalQuestions)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            Text("Which languages do you want to learn?")
                .font(.custom("PlayfairDisplay-Regular", size: 32))
                .tracking(-2.56)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.top, 32)

            Text(languageCapCopy)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            List {
                ForEach(Array(state.languagePreferences.enumerated()), id: \.element.id) { index, pref in
                    LanguagePreferenceRow(
                        pref: pref,
                        onTap: { attribute in
                            activeEdit = EditTarget(index: index, attribute: attribute)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    state.languagePreferences.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    state.languagePreferences.remove(atOffsets: offsets)
                }

                Button {
                    Haptics.light()
                    addLanguage {
                        let next = nextDefault()
                        state.languagePreferences.append(next)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: atLanguageCap ? "crown.fill" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text(atLanguageCap ? "Upgrade for more languages" : "Add language")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(.black)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)

            if !state.destinations.isEmpty {
                suggestionsSection
            }

            Spacer(minLength: 0)

            Button {
                Haptics.medium()
                onNext()
            } label: {
                Text(ctaTitle ?? "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canContinue ? Color.black : Color.gray.opacity(0.4))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSuggestionsIfNeeded()
        }
        .sheet(item: $activeEdit) { edit in
            Group {
                if edit.attribute == .dialect {
                    DialectPickerSheet(
                        language: state.languagePreferences[edit.index].language,
                        selection: bindingFor(edit)
                    )
                } else {
                    AttributeOptionsSheet(
                        attribute: edit.attribute,
                        options: options(for: edit),
                        selection: bindingFor(edit)
                    )
                }
            }
            .presentationDetents([.medium, .large])
        }
        .subscriptionCapAlert($capError)
    }

    private var canContinue: Bool {
        !state.languagePreferences.isEmpty
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
                .padding(.horizontal, 24)

            HStack(spacing: 8) {
                Text("Suggested Languages")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if isLoadingSuggestions {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)

            if !isLoadingSuggestions && visibleSuggestions.isEmpty {
                Text("No suggestions for these destinations.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleSuggestions) { suggestion in
                            Button {
                                Haptics.light()
                                addLanguage {
                                    state.languagePreferences.append(suggestion)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("\(suggestion.language) · \(suggestion.dialect) · \(suggestion.level)")
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().stroke(Color(white: 0.85), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private func loadSuggestionsIfNeeded() async {
        guard !hasFetchedSuggestions, !state.destinations.isEmpty else { return }
        hasFetchedSuggestions = true
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        do {
            let result = try await DeckGenerator.suggestLanguages(
                forDestinations: state.destinations.map { $0.name }
            )
            suggestedLanguages = result
        } catch {
            print("Failed to fetch language suggestions: \(error)")
        }
    }

    private func nextDefault() -> LanguagePreference {
        // Suggest a language the user hasn't picked yet so the row appears
        // visually distinct from existing entries.
        let used = Set(state.languagePreferences.map { $0.language })
        let suggestions = ["Mandarin", "Spanish", "French", "Japanese", "Korean", "Italian"]
        let pick = suggestions.first { !used.contains($0) } ?? "Spanish"
        let dialect = dialects(for: pick).first ?? "Standard"
        let level = levels(for: pick).first ?? "A1"
        return LanguagePreference(language: pick, dialect: dialect, level: level)
    }

    private func options(for edit: EditTarget) -> [String] {
        let language = state.languagePreferences[edit.index].language
        switch edit.attribute {
        case .level:    return levels(for: language)
        case .dialect:  return dialects(for: language)
        default:        return edit.attribute.options
        }
    }

    private func bindingFor(_ edit: EditTarget) -> Binding<String> {
        let index = edit.index
        switch edit.attribute {
        case .language:
            return Binding(
                get: { state.languagePreferences[index].language },
                set: { state.updateLanguage(at: index, to: $0) }
            )
        case .dialect:
            return Binding(
                get: { state.languagePreferences[index].dialect },
                set: { state.languagePreferences[index].dialect = $0 }
            )
        case .level:
            return Binding(
                get: { state.languagePreferences[index].level },
                set: { state.languagePreferences[index].level = $0 }
            )
        default:
            return .constant("")
        }
    }
}

private struct LanguagePreferenceRow: View {
    let pref: LanguagePreference
    let onTap: (DeckAttribute) -> Void

    // Width of the gradient fade on each edge. The pills slide under it,
    // creating the impression that the row content lives beneath the row's
    // delete (leading) and reorder (trailing) edit-mode controls.
    private let fadeWidth: CGFloat = 16

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(pref.language) { onTap(.language) }
                pill(pref.dialect)  { onTap(.dialect) }
                pill(pref.level)    { onTap(.level) }
            }
            .padding(.horizontal, fadeWidth)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
            }
        }
    }

    private func pill(_ text: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.93)))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}
