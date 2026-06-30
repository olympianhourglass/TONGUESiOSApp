import SwiftUI

// Lets the user pick which language they want to converse in. Mirrors
// the structure used elsewhere in the app: language → dialect → level,
// each filtered against the others via the existing LanguageData
// helpers, so a Mandarin pick offers HSK levels, a Japanese pick
// offers JLPT, etc.
struct ConversationLanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedLanguage: String
    @Binding var selectedDialect: String
    @Binding var selectedLevel: String
    let onConfirm: () -> Void

    private let allLanguages = DeckAttribute.language.options

    var body: some View {
        NavigationStack {
            List {
                Section("Language") {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(allLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Dialect") {
                    Picker("Dialect", selection: $selectedDialect) {
                        ForEach(currentDialects, id: \.self) { d in
                            Text(d).tag(d)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Level") {
                    Picker("Level", selection: $selectedLevel) {
                        ForEach(currentLevels, id: \.self) { l in
                            Text(l).tag(l)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            .navigationTitle("Practice language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        Haptics.medium()
                        snapDialectAndLevelIfStale()
                        onConfirm()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: selectedLanguage) { _, _ in
                snapDialectAndLevelIfStale()
            }
        }
    }

    private var currentDialects: [String] {
        dialects(for: selectedLanguage)
    }

    private var currentLevels: [String] {
        levels(for: selectedLanguage)
    }

    // Whenever the language changes, the previously chosen dialect /
    // level may no longer be valid (e.g. JLPT N3 isn't a Spanish
    // level). Snap to the first valid option in each list.
    private func snapDialectAndLevelIfStale() {
        if !currentDialects.contains(selectedDialect) {
            selectedDialect = currentDialects.first ?? "Standard"
        }
        if !currentLevels.contains(selectedLevel) {
            selectedLevel = currentLevels.first ?? "B1"
        }
    }
}
