import SwiftUI

struct AttributeOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attribute: DeckAttribute
    let options: [String]
    @Binding var selection: String

    @State private var searchText = ""

    private var filteredOptions: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredOptions, id: \.self) { option in
                    Button {
                        Haptics.light()
                        selection = option
                        dismiss()
                    } label: {
                        HStack {
                            Text(option)
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
            .navigationTitle(attribute.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search \(attribute.title.lowercased())"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(DialectSort.allCases) { order in
                        Text(order.rawValue)
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
                                    Text(dialect.name)
                                        .font(.custom("NeueHaasDisplay-Light", size: 17))
                                        .foregroundStyle(.black)
                                    if dialect.speakers > 0 {
                                        Text(formatSpeakers(dialect.speakers))
                                            .font(.custom("NeueHaasDisplay-Light", size: 12))
                                            .foregroundStyle(.red)
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
            .navigationTitle("Dialect")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search dialects"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
