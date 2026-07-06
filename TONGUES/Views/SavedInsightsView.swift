import SwiftUI

// Two-section browser for the learner's saved insights, reached from
// Profile → "View saved insights". A segmented control switches between
// grammatical insights (saved from a conversation's grammar breakdown)
// and cultural insights (saved from the Explore card). Tapping a row
// opens the insight in full — grammatical rows reuse the rich
// GrammarBreakdownSheet; cultural rows open a simple detail sheet.
struct SavedInsightsView: View {
    private enum Segment: String, CaseIterable {
        case grammatical = "Grammatical"
        case cultural = "Cultural"

        var kind: SavedInsight.Kind {
            self == .grammatical ? .grammatical : .cultural
        }
    }

    @State private var segment: Segment = .grammatical
    @State private var insights: [SavedInsight] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedGrammar: SavedInsight?
    @State private var selectedCultural: SavedInsight?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Category", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { seg in
                        Text(seg.rawValue).tag(seg)
                    }
                }
                .pickerStyle(.segmented)

                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .navigationTitle("Saved Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $selectedGrammar) { insight in
            GrammarBreakdownSheet(saved: insight)
        }
        .sheet(item: $selectedCultural) { insight in
            CulturalInsightDetailView(insight: insight)
        }
    }

    private var rows: [SavedInsight] {
        insights.filter { $0.kind == segment.kind }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading your saved insights…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else if let loadError {
            Text(loadError)
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if rows.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { insight in
                    row(insight)
                    if insight.id != rows.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: segment == .grammatical ? "text.book.closed" : "globe")
                .font(.system(size: 30))
                .foregroundStyle(Color(white: 0.7))
            Text(segment == .grammatical
                 ? "No saved grammar insights yet."
                 : "No saved cultural insights yet.")
                .font(.system(size: 15))
                .foregroundStyle(.black)
            Text(segment == .grammatical
                 ? "Tap the bookmark on a grammar breakdown in a conversation to keep it here."
                 : "Tap Save on a cultural insight in Explore to keep it here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func row(_ insight: SavedInsight) -> some View {
        Button {
            Haptics.light()
            switch insight.kind {
            case .grammatical: selectedGrammar = insight
            case .cultural: selectedCultural = insight
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(insight.title)
                        .font(.custom("NeueHaasDisplay-Roman", size: 17))
                        .foregroundStyle(.black)
                        .lineLimit(2)
                    Text(insight.subtitle?.nilIfBlank ?? insight.body)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(metadataLine(for: insight))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.6))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.7))
                    .padding(.top, 2)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await remove(insight) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // "Chinese · Jul 6, 2026" when a language is tagged, otherwise date only.
    private func metadataLine(for insight: SavedInsight) -> String {
        let date = Self.dateFormatter.string(from: insight.createdAt)
        if let language = insight.language, !language.isEmpty {
            return "\(language) · \(date)"
        }
        return date
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            insights = try await FirebaseSavedInsightService.fetchAll()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func remove(_ insight: SavedInsight) async {
        // Optimistic: drop locally, then delete server-side.
        insights.removeAll { $0.id == insight.id }
        try? await FirebaseSavedInsightService.delete(id: insight.id)
    }
}

// Simple full-context view for a saved cultural insight — mirrors the
// Explore card's dark gradient so it reads as the same artifact.
struct CulturalInsightDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let insight: SavedInsight

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("CULTURAL INSIGHT")
                        .font(.custom("NeueHaasDisplay-Mediu", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 44)

                    Text(insight.title)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 24))
                        .foregroundStyle(.white)

                    if let language = insight.language, !language.isEmpty {
                        Text(language)
                            .font(.custom("NeueHaasDisplay-Light", size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }

                    Text(insight.body)
                        .font(.custom("NeueHaasDisplay-Light", size: 17))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Saved \(Self.dateFormatter.string(from: insight.createdAt))")
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
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
            .padding(.trailing, 16)
        }
        .presentationBackground(.black)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
