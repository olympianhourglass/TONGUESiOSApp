import SwiftUI
import WidgetKit

// In-app companion to the Word Cycle widget. iOS owns each home-screen
// widget instance's actual configuration, so this view can't read or
// write any specific deployed widget — but it does let the user
// preview every source they could pick (FSRS + each language + each
// deck), tweak the color, and reload all timelines.
//
// Layout mirrors what the Edit Widget panel exposes:
//   - One unified source picker (chips, scrollable horizontally)
//   - One background color picker (the palette swatches)
//   - A live preview that recomposes as you tap each chip / swatch
struct WordCycleWidgetSection: View {

    struct LocalSource: Identifiable, Hashable {
        enum Kind: String { case fsrs, language, deck }

        let id: String
        let title: String
        let subtitle: String
        let kind: Kind
        let value: String?  // language name for .language; deckID for .deck

        static let fsrs = LocalSource(
            id: "fsrs",
            title: "Most at risk",
            subtitle: "FSRS · all decks",
            kind: .fsrs,
            value: nil
        )

        static func language(_ name: String) -> LocalSource {
            LocalSource(id: "lang:\(name)", title: name, subtitle: "Language · Words", kind: .language, value: name)
        }

        static func deck(deckID: String, title: String, language: String) -> LocalSource {
            LocalSource(id: "deck:\(deckID)", title: title, subtitle: "\(language) · Words", kind: .deck, value: deckID)
        }
    }

    @State private var snapshot: WidgetSnapshot?
    @State private var selectedSourceID: String = "fsrs"
    @State private var backgroundHex: String = WidgetBackgroundColorStore.read()
    @State private var didReloadOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            preview
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            colorPicker

            sourceScroller

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .task { loadSnapshot() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Word Cycle Widget")
                .font(.custom("NeueHaasDisplay-Bold", size: 15))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            Button {
                Haptics.light()
                WidgetCenter.shared.reloadAllTimelines()
                loadSnapshot()
                didReloadOnce = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didReloadOnce ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didReloadOnce ? "Refreshed" : "Refresh")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.glass(.clear))
        }
    }

    // MARK: - Preview

    private var preview: some View {
        WordCycleMiniPreview(
            card: previewCard,
            headerLabel: previewHeaderLabel,
            background: Color(libraryHex: backgroundHex),
            // Black text on light backgrounds (e.g. the "Pleasant" blue),
            // white on the dark ones — matching the real widget so the
            // preview reflects what actually renders.
            foreground: backgroundHex.widgetPreviewLuminance > 0.7 ? .black : .white
        )
    }

    // Mirrors the provider's pool logic so what shows here matches
    // what the deployed widget would render for the same source.
    private var previewCard: WidgetCard? {
        guard let snapshot else { return nil }
        let source = selectedSource
        switch source.kind {
        case .fsrs:
            return snapshot.cards.first
        case .language:
            guard let target = source.value else { return nil }
            return snapshot.cards.first { $0.language == target && $0.contentType == "Words" }
        case .deck:
            guard let target = source.value else { return nil }
            return snapshot.cards.first { $0.deckID == target && $0.contentType == "Words" }
        }
    }

    private var previewHeaderLabel: String {
        guard let card = previewCard else { return "" }
        switch selectedSource.kind {
        case .fsrs, .language:
            return Self.shortLanguageLabel(card.language)
        case .deck:
            return card.deckTitle
        }
    }

    // MARK: - Color picker

    private var colorPicker: some View {
        // Horizontally scrollable so the swatch row never clips on narrow
        // screens as the palette grows.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(WidgetBackgroundColorStore.palette, id: \.self) { hex in
                    Button {
                        Haptics.light()
                        backgroundHex = hex
                        WidgetBackgroundColorStore.write(hex)
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Circle()
                            .fill(Color(libraryHex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(backgroundHex == hex ? 1 : 0.25),
                                    lineWidth: backgroundHex == hex ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    // MARK: - Source scroller

    private var sourceScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableSources) { source in
                    sourceChip(source)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func sourceChip(_ source: LocalSource) -> some View {
        let isSelected = source.id == selectedSourceID
        return Button {
            Haptics.light()
            selectedSourceID = source.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(isSelected ? .black : .white)
                    .lineLimit(1)
                Text(source.subtitle)
                    .font(.custom("NeueHaasDisplay-Light", size: 10))
                    .foregroundStyle(isSelected ? .black.opacity(0.55) : .white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(isSelected ? 1 : 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(statusLine)
            .font(.custom("NeueHaasDisplay-Light", size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLine: String {
        guard let snapshot else {
            return "No widget data yet. Pull-to-refresh the Library to populate."
        }
        let cards = snapshot.cards.count
        let decks = snapshot.decks.count
        if cards == 0 {
            return "Add a deck to start cycling words on the widget."
        }
        return "Previewing one of \(availableSources.count) widget configurations. Each home-screen widget picks its own source + color via long-press → Edit Widget. Snapshot: \(cards) card\(cards == 1 ? "" : "s") across \(decks) deck\(decks == 1 ? "" : "s")."
    }

    // MARK: - Sources

    // The flat list the Edit Widget dropdown also draws from: FSRS at
    // the top, every language alphabetically, every deck in snapshot
    // order. Computed each render so it tracks the snapshot live.
    private var availableSources: [LocalSource] {
        var result: [LocalSource] = [.fsrs]
        guard let snapshot else { return result }
        for lang in snapshot.languages {
            result.append(.language(lang))
        }
        for deck in snapshot.decks {
            result.append(.deck(deckID: deck.deckID, title: deck.title, language: deck.language))
        }
        return result
    }

    private var selectedSource: LocalSource {
        availableSources.first { $0.id == selectedSourceID } ?? .fsrs
    }

    // MARK: - Snapshot load

    private func loadSnapshot() {
        snapshot = WidgetSnapshotIO.read()
        // If the currently-selected source vanished (e.g., the user
        // deleted that deck), fall back to FSRS so the preview never
        // empties out.
        if !availableSources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = "fsrs"
        }
    }

    // "Chinese (Mandarin)" → "Mandarin"
    private static func shortLanguageLabel(_ language: String) -> String {
        if let open = language.firstIndex(of: "("),
           let close = language.firstIndex(of: ")"),
           open < close {
            return String(language[language.index(after: open)..<close])
        }
        return language
    }
}

// Visual replica of the widget's small-family layout, rendered in the
// main app so users can preview without needing to install the widget.
private struct WordCycleMiniPreview: View {
    let card: WidgetCard?
    let headerLabel: String
    let background: Color
    // Legible text/element color for the chosen background.
    var foreground: Color = .white

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            if let card {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headerLabel)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(foreground.opacity(0.55))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(card.english)
                        .font(.custom("NeueHaasDisplay-Light", size: 15))
                        .foregroundStyle(foreground.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Text(card.foreign)
                        .font(.custom("NeueHaasDisplay-Bold", size: 26))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .padding(.top, 2)

                    Spacer(minLength: 0)
                }
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No cards yet")
                        .font(.custom("NeueHaasDisplay-Light", size: 14))
                        .foregroundStyle(foreground.opacity(0.6))
                    Text("Add a deck to start cycling words.")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .foregroundStyle(foreground.opacity(0.45))
                        .lineLimit(2)
                }
                .padding(14)
            }
        }
    }
}

private extension String {
    // Rec. 601 perceived luminance (0 = black, 1 = white) of a 6-char hex
    // string, used to pick a legible foreground over the widget preview
    // background. Returns 0 (treated as dark) for malformed input.
    var widgetPreviewLuminance: Double {
        var value: UInt64 = 0
        guard Scanner(string: self).scanHexInt64(&value), self.count == 6 else { return 0 }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

// Companion section for the lock screen widget. Unlike the home
// screen widget (per-instance config via Edit Widget), the lock
// screen widget reads a single shared "preferred language" from App
// Group UserDefaults. This picker is the only way to change it — by
// design, since the user asked for language to be controlled from
// the Profile page.
struct LockScreenWidgetSection: View {
    @State private var snapshot: WidgetSnapshot?
    @State private var selectedLanguage: String?
    @State private var didReloadOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            languageMenu
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .task { load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lock Screen Widget")
                .font(.custom("NeueHaasDisplay-Bold", size: 15))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            Button {
                Haptics.light()
                WidgetCenter.shared.reloadAllTimelines()
                didReloadOnce = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didReloadOnce ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didReloadOnce ? "Refreshed" : "Refresh")
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.glass(.clear))
        }
    }

    private var languageMenu: some View {
        let languages = snapshot?.languages ?? []
        let current = selectedLanguage
            ?? languages.first
            ?? "—"
        return Menu {
            ForEach(languages, id: \.self) { lang in
                Button(lang) {
                    Haptics.light()
                    selectedLanguage = lang
                    WidgetLockScreenLanguageStore.write(lang)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Language")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Text(current)
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.white.opacity(languages.isEmpty ? 0.4 : 1))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
        }
        .disabled(languages.isEmpty)
    }

    private var footer: some View {
        Text("Cycles random words (no phrases) from this language on every lock screen widget. Pick once here — it applies to every lock screen instance.")
            .font(.custom("NeueHaasDisplay-Light", size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        snapshot = WidgetSnapshotIO.read()
        if selectedLanguage == nil {
            selectedLanguage = WidgetLockScreenLanguageStore.read()
                ?? snapshot?.languages.first
        }
    }
}

// Hex → Color for the main app's preview swatches. Same parsing as
// the widget extension's `Color(widgetHex:)`; lives separately so each
// target compiles standalone without sharing SwiftUI helpers.
extension Color {
    init(libraryHex hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else {
            self = Color(red: 78 / 255, green: 91 / 255, blue: 101 / 255)
            return
        }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
