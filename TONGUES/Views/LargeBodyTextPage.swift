import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// Large-body-text page (Create New Deck → page 4). User pastes text
// or uploads a PDF; we hand it to Claude Haiku 4.5 to identify
// study-worthy words, render them as a multi-select list, and let the
// user save the selection to an existing deck or seed a new one. Same
// save flow CameraPage / DirectPage already use.

struct LargeBodyTextPage: View {
    @Binding var language: String
    @Binding var dialect: String
    let level: String
    let onAttributeTap: (DeckAttribute) -> Void
    let onSaved: () -> Void

    // Caps the request size so each call stays in the ≈$0.013 ceiling
    // on Haiku 4.5. Anything bigger gets truncated with a heads-up.
    static let maxInputChars = 20_000
    // Hard ceiling on raw upload size, applied before any per-format
    // extraction so the user gets an immediate "too big" instead of a
    // silent OOM on a 200MB file.
    static let maxUploadBytes = 10 * 1024 * 1024

    // Document types the file importer offers. Each one maps to a
    // native iOS extractor (PDFKit / NSAttributedString / direct file
    // read). DOCX is intentionally not in this list — iOS's
    // NSAttributedString reader doesn't support it (`.officeOpenXML`
    // is macOS-only). The error message in `extractText(from:)` tells
    // the user to re-export as PDF / RTF / TXT.
    static var allowedDocumentTypes: [UTType] {
        [.pdf, .plainText, .text, .rtf]
    }

    @State private var sourceText: String = ""
    @State private var extracted: DeckGenerator.ExtractedBody?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var isProcessing = false
    @State private var truncationNotice: String?
    @State private var errorText: String?
    @State private var showPasteSheet = false
    @State private var showFileImporter = false
    @State private var showDeckPicker = false
    @State private var showCreateCover = false
    @State private var isSavingNewDeck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                attributesSection
                sourceActions
                if let notice = truncationNotice {
                    truncationBanner(notice)
                }
                if !sourceText.isEmpty {
                    sourceCard
                }
                if isProcessing {
                    processingBanner
                }
                if let extracted, !extracted.items.isEmpty {
                    extractedList(extracted)
                    saveActions
                }
            }
            .padding(.horizontal, 8)
            // Clears the parent sheet's custom close-X overlay
            // (8pt top inset + 36pt circle = 44pt) plus breathing room.
            .padding(.top, 80)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteTextSheet(maxChars: Self.maxInputChars) { text in
                showPasteSheet = false
                loadSourceText(text, source: "paste")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.allowedDocumentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showDeckPicker) {
            // Items always carry the *resolved* language — for
            // English source that's the user-picked target; for any
            // foreign source it's whatever Claude detected, with the
            // user's selection intentionally ignored per spec.
            DeckPickerSheet(
                itemsToAdd: selectedItems,
                sourceLanguage: resolvedLanguage,
                sourceDialect: resolvedDialect,
                onAdded: {
                    showDeckPicker = false
                    onSaved()
                }
            )
        }
        .sheet(isPresented: $showCreateCover) {
            DeckCoverCustomizationSheet(
                initialTitle: defaultDeckTitle,
                language: resolvedLanguage,
                level: level
            ) { newTitle, chosenStyle, isPublic in
                showCreateCover = false
                Task {
                    await saveAsNewDeck(
                        title: newTitle,
                        style: chosenStyle,
                        isPublic: isPublic
                    )
                }
            }
            .presentationDetents([.fraction(0.8), .large])
        }
    }

    // MARK: Attributes

    private var attributesSection: some View {
        HStack(alignment: .top, spacing: 12) {
            attribute(.language, value: language)
            attribute(.dialect, value: dialect)
            Spacer(minLength: 0)
        }
    }

    private func attribute(_ kind: DeckAttribute, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(.black)
                .lineLimit(1)
            Button {
                Haptics.light()
                onAttributeTap(kind)
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.custom("NeueHaasDisplay-Light", size: 16))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Source actions

    private var sourceActions: some View {
        HStack(spacing: 12) {
            sourceButton(label: "Upload Document", icon: "doc.fill") {
                Haptics.light()
                showFileImporter = true
            }
            sourceButton(label: "Paste Text", icon: "doc.on.clipboard") {
                Haptics.light()
                showPasteSheet = true
            }
        }
    }

    private func sourceButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Truncation banner

    private func truncationBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            Text(message)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: Source card (text the user gave us; highlighted study words)

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Source")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(sourceText.count) chars")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    Haptics.light()
                    clearSource()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
            }
            ScrollView {
                Text(highlightedSource)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    // Builds an AttributedString that underlines each extracted study
    // word inside the source. Substring match per item — works well
    // for Latin scripts and acceptable for most others; non-Latin
    // scripts without spaces (Chinese / Japanese) still get a
    // best-effort highlight on the canonical form.
    private var highlightedSource: AttributedString {
        var attributed = AttributedString(sourceText)
        guard let items = extracted?.items else { return attributed }
        for item in items {
            let needle = preferredHighlightString(for: item)
            guard !needle.isEmpty,
                  let range = attributed.range(of: needle, options: .caseInsensitive) else {
                continue
            }
            attributed[range].backgroundColor = Color.yellow.opacity(0.35)
            attributed[range].font = .system(size: 15, weight: .semibold)
        }
        return attributed
    }

    // English-source items live in `translation`; foreign-source items
    // live in `word`. Highlight whichever one actually appears in the
    // text the user gave us.
    private func preferredHighlightString(for item: GeneratedItem) -> String {
        guard let extracted else { return item.word }
        switch extracted.direction {
        case .fromEnglish: return item.translation  // source was English
        case .toEnglish:   return item.word         // source was foreign
        }
    }

    // MARK: Processing banner

    private var processingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.black)
            Text("Picking out study-worthy words…")
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.92), lineWidth: 1)
        )
    }

    // MARK: Extracted list

    private func extractedList(_ extracted: DeckGenerator.ExtractedBody) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if extracted.direction == .toEnglish && extracted.resolvedLanguage != language {
                // Foreign-source override notice: the user's
                // selection was ignored because the pasted text was
                // identified as another language.
                Text("Detected as \(extracted.resolvedLanguage) — saving picks in that language regardless of your selection.")
                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.95))
                    )
            }
            HStack {
                Text(extracted.direction == .fromEnglish ? "Translated picks" : "Picks to study")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(selectedItemIDs.count) / \(extracted.items.count) selected")
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.secondary)
                Button(allSelected(in: extracted) ? "Deselect all" : "Select all") {
                    Haptics.light()
                    if allSelected(in: extracted) {
                        selectedItemIDs.removeAll()
                    } else {
                        selectedItemIDs = Set(extracted.items.map(\.id))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
            }
            VStack(spacing: 0) {
                ForEach(extracted.items) { item in
                    extractedRow(item)
                    if item.id != extracted.items.last?.id {
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

    private func extractedRow(_ item: GeneratedItem) -> some View {
        let selected = selectedItemIDs.contains(item.id)
        return Button {
            Haptics.light()
            if selected {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? .black : Color(white: 0.7))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.word)
                        .font(.custom("PlayfairDisplay-Regular", size: 18))
                        .foregroundStyle(.black)
                        .lineLimit(2)
                    Text(item.translation)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let translit = item.transliteration, !translit.isEmpty {
                        Text(translit)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func allSelected(in extracted: DeckGenerator.ExtractedBody) -> Bool {
        !extracted.items.isEmpty && selectedItemIDs.count == extracted.items.count
    }

    private var selectedItems: [GeneratedItem] {
        guard let extracted else { return [] }
        return extracted.items.filter { selectedItemIDs.contains($0.id) }
    }

    // Source-aware resolved language/dialect (see ExtractedBody for
    // the rule). For foreign source we ignore the user's selection
    // and use whatever Claude detected so the save lands in the
    // right deck.
    private var resolvedLanguage: String {
        extracted?.resolvedLanguage ?? language
    }
    private var resolvedDialect: String {
        extracted?.resolvedDialect ?? dialect
    }

    // MARK: Save actions (mirror DeckResultsView / CameraPage)

    private var saveActions: some View {
        HStack(spacing: 12) {
            ActionCard(
                title: isSavingNewDeck ? "Saving…" : "Create New Deck",
                systemImage: isSavingNewDeck ? "arrow.up.circle" : "square.stack.3d.up",
                isPrimary: false
            ) {
                Haptics.medium()
                showCreateCover = true
            }
            .disabled(selectedItems.isEmpty || isSavingNewDeck)
            ActionCard(title: "Save to Deck", systemImage: "plus.circle", isPrimary: true) {
                Haptics.medium()
                showDeckPicker = true
            }
            .disabled(selectedItems.isEmpty || isSavingNewDeck)
        }
    }

    // MARK: Source intake

    private func loadSourceText(_ raw: String, source: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "That \(source) was empty."
            return
        }
        let (capped, didTruncate) = clamp(trimmed, to: Self.maxInputChars)
        sourceText = capped
        truncationNotice = didTruncate
            ? "Trimmed to the first \(Self.maxInputChars.formatted()) characters to keep the cost predictable."
            : nil
        extracted = nil
        selectedItemIDs = []
        Task { await runExtraction() }
    }

    private func clamp(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return (String(text[..<endIndex]), true)
    }

    private func clearSource() {
        sourceText = ""
        extracted = nil
        selectedItemIDs = []
        truncationNotice = nil
    }

    // MARK: PDF import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // Document picker hands back a security-scoped URL; we
            // have to start access before reading and stop after.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = attributes.fileSize, size > Self.maxUploadBytes {
                errorText = "That file is \(formatBytes(size)). Please upload one under \(formatBytes(Self.maxUploadBytes))."
                return
            }
            let (text, kind) = try extractText(from: url)
            guard !text.isEmpty else {
                errorText = kind == "PDF"
                    ? "Couldn't read any text from that PDF — it may be a scan without an OCR layer."
                    : "Couldn't read any text out of that \(kind)."
                return
            }
            loadSourceText(text, source: kind)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Dispatches to the right per-format extractor based on the file's
    // extension. PDF goes through PDFKit; RTF and DOCX go through
    // `NSAttributedString` which strips formatting and hands back the
    // plain string Claude needs; plain text reads directly. Any
    // unrecognized extension gets a best-effort UTF-8 text read.
    private func extractText(from url: URL) throws -> (String, String) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw NSError(
                    domain: "LargeBodyTextPage", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't open that PDF."]
                )
            }
            return (extractPDF(document), "PDF")
        case "rtf":
            return (try extractAttributedString(url: url, type: .rtf), "RTF")
        case "doc", "docx":
            // Word formats aren't supported on iOS: .docx requires
            // macOS-only `.officeOpenXML`; .doc is legacy binary.
            // Tell the user clearly instead of failing silently.
            throw NSError(
                domain: "LargeBodyTextPage", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Word files aren't supported yet — re-save as PDF, RTF, or plain text."]
            )
        default:
            // Plain text / .txt / unknown — try UTF-8 first.
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return (text, "Text file")
            }
            // Last-ditch fallback: ASCII (catches some legacy
            // exports). Anything else surfaces as a real error.
            return (try String(contentsOf: url, encoding: .ascii), "Text file")
        }
    }

    private func extractPDF(_ document: PDFDocument) -> String {
        var accumulated = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let pageText = page.string else { continue }
            accumulated += pageText + "\n"
            // Bail early once we hit the cap so we don't pay to
            // extract pages we're going to throw away anyway.
            if accumulated.count > Self.maxInputChars { break }
        }
        return accumulated
    }

    private func extractAttributedString(
        url: URL,
        type: NSAttributedString.DocumentType
    ) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type
        ]
        let attributed = try NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        )
        return attributed.string
    }

    private func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    // MARK: Extraction call

    @MainActor
    private func runExtraction() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let result = try await DeckGenerator.extractStudyWords(
                from: sourceText,
                foreignLanguage: language,
                dialect: dialect,
                level: level
            )
            Haptics.success()
            extracted = result
            selectedItemIDs = Set(result.items.map(\.id))
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    // MARK: Save flows

    private var defaultDeckTitle: String {
        let first = sourceText.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return "Reading – Picks" }
        return "Reading – \(first.prefix(28))"
    }

    @MainActor
    private func saveAsNewDeck(title: String, style: DeckCoverStyle, isPublic: Bool) async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        isSavingNewDeck = true
        defer { isSavingNewDeck = false }
        // Save under the resolved language/dialect so foreign-source
        // text (e.g. Spanish pasted while the user has French
        // selected) lands in a Spanish deck — not a French one.
        let saveLanguage = resolvedLanguage
        let saveDialect = resolvedDialect
        let deck = GeneratedDeck(
            title: title,
            items: items.map { $0.withLanguage(saveLanguage) },
            language: saveLanguage,
            dialect: saveDialect,
            level: level,
            contentType: "Words",
            amount: "\(items.count)",
            tones: [],
            interests: [],
            userPrompt: "Large body text",
            promptSent: "",
            rawJSON: ""
        )
        do {
            _ = try await FirebaseDeckService.saveDeck(
                deck,
                title: title,
                coverStyle: style.rawValue,
                isPublic: isPublic
            )
            Haptics.success()
            onSaved()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }
}

// MARK: - Paste sheet

// Modal text editor for pasting a body of text. The plain TextEditor
// would have shipped a similar UX but having its own sheet means the
// page stays uncluttered and we can show a char-count gauge that
// turns red as the user approaches the cap.
struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let maxChars: Int
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.custom("NeueHaasDisplay-Light", size: 16))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .focused($isEditorFocused)
                    // Auto-capitalize each word's first letter as the
                    // user types into the body-text editor.
                    .textInputAutocapitalization(.words)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.88), lineWidth: 1)
                    )
                HStack {
                    Text("\(text.count) / \(maxChars) characters")
                        .font(.system(size: 12))
                        .foregroundStyle(text.count > maxChars ? .red : .secondary)
                    Spacer()
                    Button("Paste from clipboard") {
                        if let pasted = UIPasteboard.general.string {
                            Haptics.light()
                            text = pasted
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                }
            }
            .padding(20)
            .navigationTitle("Paste text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") {
                        Haptics.medium()
                        onSubmit(text)
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isEditorFocused = true }
        }
    }
}
