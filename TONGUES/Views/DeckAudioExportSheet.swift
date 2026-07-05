import SwiftUI
import UIKit

// Options sheet shown before downloading a deck as audio. Mirrors the
// Listen session's playback options (read native, order, gap, speed) and,
// on Download, synthesizes the deck to an .m4a and hands the file URL back
// for sharing.
struct DeckAudioExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: DeckDocument
    let onExported: (URL) -> Void

    // Seed from the user's Listen preferences so the export matches how
    // they like to hear decks; changes here stay local to the export.
    @AppStorage("listenReadTranslation") private var listenReadTranslation = false
    @AppStorage("listenTranslationOrder") private var listenTranslationOrder = "before"
    @AppStorage("listenGapSeconds") private var listenGap = 2
    @AppStorage("listenTurtle") private var listenTurtle = false

    @State private var readNative = false
    @State private var nativeBefore = true
    @State private var gapSeconds = 2
    @State private var slower = false

    @State private var isGenerating = false
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Color.white.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Download as audio")
                            .font(.custom("PlayfairDisplay-Regular", size: 28))
                            .tracking(-1.5)
                            .foregroundStyle(.black)
                            .padding(.top, 40)

                        Text("Choose how the deck should sound, then download an audio file.")
                            .font(.custom("NeueHaasDisplay-Light", size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        choiceRow(
                            "Read the native translation aloud",
                            options: [("No", false), ("Yes", true)],
                            selection: $readNative
                        )

                        if readNative {
                            choiceRow(
                                "Native order",
                                options: [("Before", true), ("After", false)],
                                selection: $nativeBefore
                            )
                        }

                        choiceRow(
                            "Seconds between words",
                            options: [("2", 2), ("4", 4), ("8", 8)],
                            selection: $gapSeconds
                        )

                        choiceRow(
                            "Playback speed",
                            options: [("Normal", false), ("Slower", true)],
                            selection: $slower
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }

                closeButton
            }
            .safeAreaInset(edge: .bottom) {
                downloadButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .background(Color.white)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("Export failed", isPresented: errorBinding) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            readNative = listenReadTranslation
            nativeBefore = listenTranslationOrder == "before"
            gapSeconds = listenGap
            slower = listenTurtle
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.top, 16)
        .padding(.trailing, 8)
        .disabled(isGenerating)
    }

    private var downloadButton: some View {
        Button {
            Haptics.medium()
            Task { await generate() }
        } label: {
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView().tint(.white)
                    Text("Generating… \(Int(progress * 100))%")
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                    Text("Download")
                }
            }
            .font(.custom("NeueHaasDisplay-Light", size: 17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.black))
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    private func choiceRow<T: Hashable>(
        _ label: String,
        options: [(String, T)],
        selection: Binding<T>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.custom("NeueHaasDisplay-Light", size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options, id: \.1) { title, value in
                    Button {
                        Haptics.light()
                        selection.wrappedValue = value
                    } label: {
                        Text(title)
                            .font(.custom("NeueHaasDisplay-Light", size: 15))
                            .foregroundStyle(selection.wrappedValue == value ? .white : .black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    selection.wrappedValue == value
                                        ? Color.black
                                        : Color.black.opacity(0.05)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)
                }
            }
        }
    }

    private func generate() async {
        isGenerating = true
        progress = 0
        defer { isGenerating = false }
        let settings = DeckExporter.AudioSettings(
            readNative: readNative,
            nativeBefore: nativeBefore,
            gapSeconds: gapSeconds,
            slower: slower
        )
        do {
            let url = try await DeckExporter.makeAudio(for: deck, settings: settings) { p in
                progress = p
            }
            Haptics.success()
            onExported(url)
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }
}

// Lightweight UIActivityViewController wrapper for sharing a generated file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// Identifiable URL wrapper so a generated file can drive `.sheet(item:)`.
struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
