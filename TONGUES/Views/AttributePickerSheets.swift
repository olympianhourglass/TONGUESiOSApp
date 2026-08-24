import SwiftUI

// Applies the given modifier only when `condition` is true. `attribute`
// is constant for a sheet's lifetime, so the branch never flips and view
// identity stays stable.
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

struct AttributeOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attribute: DeckAttribute
    let options: [String]
    @Binding var selection: String

    @State private var searchText = ""
    // Recently-used languages, loaded once on appear.
    @State private var recents: [String] = []

    // Only the long language list benefits from a search field; the
    // content / amount / level pickers have just a couple of options each,
    // so the search bar is hidden for those.
    private var showsSearch: Bool { attribute == .language }

    private var filteredOptions: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        // Match either the English value or its localized display name, so a
        // user searching in their own language still finds the language.
        return options.filter {
            $0.localizedCaseInsensitiveContains(query)
                || localizedAttributeValue($0, for: attribute).localizedCaseInsensitiveContains(query)
        }
    }

    // Recently-used languages that are still valid options. Only shown for
    // the language picker, and only when not actively searching.
    private var recentOptions: [String] {
        guard attribute == .language, searchText.isEmpty else { return [] }
        return recents.filter { options.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recentOptions.isEmpty {
                    Section {
                        ForEach(recentOptions, id: \.self) { option in
                            optionRow(option)
                        }
                    } header: {
                        HStack {
                            Text(L("Recently Used"))
                            Spacer()
                            Button(L("Clear")) {
                                Haptics.light()
                                RecentAttributeStore.clearLanguages()
                                recents = []
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .textCase(nil)
                        }
                    }
                    Section(L("All Languages")) {
                        ForEach(filteredOptions, id: \.self) { option in
                            optionRow(option)
                        }
                    }
                } else {
                    ForEach(filteredOptions, id: \.self) { option in
                        optionRow(option)
                    }
                }
            }
            .navigationTitle(L(attribute.title))
            .navigationBarTitleDisplayMode(.inline)
            .if(showsSearch) { view in
                view
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L("Search %@", L(attribute.title).lowercased())
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onAppear { recents = RecentAttributeStore.recentLanguages() }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: String) -> some View {
        Button {
            Haptics.light()
            selection = option
            dismiss()
        } label: {
            HStack {
                Text(localizedAttributeValue(option, for: attribute))
                    .font(.custom("NeueHaasDisplay-Light", size: 17))
                    .foregroundStyle(.black)
                Spacer()
                if option == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

// Lightweight most-recently-used tracker for the language picker. Stored
// in UserDefaults, most-recent-first, deduped, capped.
enum RecentAttributeStore {
    private static let languagesKey = "recentLanguages"
    private static let maxCount = 5

    static func recentLanguages() -> [String] {
        UserDefaults.standard.stringArray(forKey: languagesKey) ?? []
    }

    static func recordLanguage(_ language: String) {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentLanguages().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        UserDefaults.standard.set(list, forKey: languagesKey)
    }

    static func clearLanguages() {
        UserDefaults.standard.removeObject(forKey: languagesKey)
    }
}

struct DialectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let language: String
    @Binding var selection: String

    enum DialectSort: String, CaseIterable, Identifiable {
        case usage = "By Usage"
        case alphabetical = "Alphabetical"
        var id: String { rawValue }
    }

    @State private var sortOrder: DialectSort = .usage
    @State private var searchText = ""

    private var displayedDialects: [Dialect] {
        let all = dialectsDetailed(for: language)
        let sorted: [Dialect]
        switch sortOrder {
        case .alphabetical:
            sorted = all.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .usage:
            sorted = all.sorted { $0.speakers > $1.speakers }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || L($0.name).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("Sort"), selection: $sortOrder) {
                    ForEach(DialectSort.allCases) { order in
                        Text(L(order.rawValue))
                            .font(.custom("NeueHaasDisplay-Light", size: 14))
                            .tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                List {
                    ForEach(displayedDialects, id: \.name) { dialect in
                        Button {
                            Haptics.light()
                            selection = dialect.name
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(dialect.name))
                                        .font(.custom("NeueHaasDisplay-Light", size: 17))
                                        .foregroundStyle(.black)
                                    if dialect.speakers > 0 {
                                        Text(formatSpeakers(dialect.speakers))
                                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                                            .foregroundStyle(Color(white: 0.32))
                                    }
                                }
                                Spacer()
                                if dialect.name == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Dialect"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("Search dialects")
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }
}
