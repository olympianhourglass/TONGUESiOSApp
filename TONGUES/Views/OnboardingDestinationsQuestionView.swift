import SwiftUI
import MapKit

struct OnboardingDestinationsQuestionView: View {
    let questionNumber: Int
    let totalQuestions: Int
    @Bindable var state: OnboardingState
    let onNext: () -> Void
    var showsProgress: Bool = true
    // nil keeps the onboarding "Next" label; settings edit passes "Save".
    var ctaTitle: String? = nil

    @State private var showSearch = false

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

            Text(titleText)
                .font(.custom("PlayfairDisplay-Regular", size: 32))
                .tracking(-2.56)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.top, 32)

            Text("Add the cities and countries you'd love to visit. Drag to reorder by priority.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            List {
                ForEach(state.destinations) { dest in
                    DestinationRow(name: dest.name)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    state.destinations.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    state.destinations.remove(atOffsets: offsets)
                }

                Button {
                    Haptics.light()
                    showSearch = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add destination")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Skip") {
                    Haptics.light()
                    onNext()
                }
                .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSearch) {
            DestinationSearchSheet { selection in
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !state.destinations.contains(where: { $0.name == trimmed }) else { return }
                state.destinations.append(Destination(name: trimmed))
            }
        }
    }

    private var canContinue: Bool {
        !state.destinations.isEmpty
    }

    // Greet by name when Q1 was answered; fall back to the plain title if the
    // user skipped it.
    private var titleText: String {
        let trimmed = state.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? "Where are your dream destinations?"
            : "Where are your dream destinations, \(trimmed)?"
    }
}

private struct DestinationRow: View {
    let name: String
    private let fadeWidth: CGFloat = 16

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(white: 0.93)))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, fadeWidth)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
            }
        }
    }
}

// MARK: - Search sheet

struct DestinationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    @State private var searchText = ""
    @State private var model = DestinationSearchModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.results, id: \.self) { result in
                    Button {
                        Haptics.light()
                        onSelect(result)
                        dismiss()
                    } label: {
                        HStack {
                            Text(result)
                                .font(.system(size: 16))
                                .foregroundStyle(.black)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add destination")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search cities or countries"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .onChange(of: searchText) { _, newValue in
                model.search(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

@Observable
@MainActor
final class DestinationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var results: [String] = []
    private let completer: MKLocalSearchCompleter

    override init() {
        let c = MKLocalSearchCompleter()
        c.resultTypes = .address  // cities, regions, countries — excludes POIs/businesses
        self.completer = c
        super.init()
        completer.delegate = self
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let updated = completer.results.map { suggestion -> String in
            suggestion.subtitle.isEmpty
                ? suggestion.title
                : "\(suggestion.title), \(suggestion.subtitle)"
        }
        Task { @MainActor in
            self.results = updated
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            print("DestinationSearch error: \(error)")
            self.results = []
        }
    }
}
