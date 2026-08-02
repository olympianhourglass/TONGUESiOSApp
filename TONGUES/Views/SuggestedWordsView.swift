import SwiftUI

// A node in a growable web of AI-suggested related words, shown under a
// detected/translated result. Each node can be added to the deck and — up to
// the tree's max depth — expanded into more related words. Reference type so a
// tap deep in the tree mutates in place and Observation re-renders only the
// affected branch.
@MainActor
@Observable
final class WordSuggestionNode: Identifiable {
    let id = UUID()
    let item: GeneratedItem
    // 0 for a detected/translated root; each expansion is one deeper. Compared
    // against a per-mode max depth to decide whether a node can be expanded.
    let depth: Int
    var children: [WordSuggestionNode] = []
    var isLoading = false
    var isAdded = false
    var errorText: String?

    init(item: GeneratedItem, depth: Int) {
        self.item = item
        self.depth = depth
    }

    // Every word in this subtree (lowercased), so a re-expand never suggests
    // something already visible below it.
    func wordsInSubtree() -> Set<String> {
        var set: Set<String> = [item.word.lowercased()]
        for child in children { set.formUnion(child.wordsInSubtree()) }
        return set
    }
}

// Colors for the suggestion chips/rules, so the same component reads correctly
// on the camera's dark surface and on the light Direct/Conversation surfaces.
struct SuggestionPalette {
    var primaryText: Color
    var secondaryText: Color
    var glyph: Color
    var glyphAdded: Color
    var chipFill: Color
    var chipFillAdded: Color
    var chipStroke: Color
    var chipStrokeAdded: Color
    var expandIcon: Color
    var expandFill: Color
    var expandStroke: Color
    var rule: Color
    var error: Color
    var progressTint: Color

    // White-on-dark (camera).
    static let dark = SuggestionPalette(
        primaryText: .white,
        secondaryText: .white.opacity(0.55),
        glyph: .white.opacity(0.7),
        glyphAdded: .white.opacity(0.9),
        chipFill: .white.opacity(0.07),
        chipFillAdded: .white.opacity(0.16),
        chipStroke: .white.opacity(0.18),
        chipStrokeAdded: .white.opacity(0.35),
        expandIcon: .white.opacity(0.8),
        expandFill: .white.opacity(0.07),
        expandStroke: .white.opacity(0.18),
        rule: .white.opacity(0.12),
        error: Color(red: 1.0, green: 0.6, blue: 0.6),
        progressTint: .white
    )

    // Black-on-light (Direct / Conversation).
    static let light = SuggestionPalette(
        primaryText: .black,
        secondaryText: Color.secondary,
        glyph: .black.opacity(0.55),
        glyphAdded: .black.opacity(0.9),
        chipFill: .black.opacity(0.03),
        chipFillAdded: .black.opacity(0.08),
        chipStroke: .black.opacity(0.15),
        chipStrokeAdded: .black.opacity(0.32),
        expandIcon: .black.opacity(0.6),
        expandFill: .black.opacity(0.035),
        expandStroke: .black.opacity(0.15),
        rule: .black.opacity(0.12),
        error: .red,
        progressTint: .black
    )
}

// Renders a list of suggestion nodes (the children of some parent), each as an
// add-chip plus an optional expand button, with their own children indented
// beneath a thin rule. Recursive: a node's children render the same way.
struct SuggestionChildrenView: View {
    let nodes: [WordSuggestionNode]
    // Nodes at depth < maxDepth show an expand (sparkles) button. AR passes 1
    // (children are leaves); Direct/Conversation/Sign/Object pass a larger cap
    // so the web grows.
    let maxDepth: Int
    var palette: SuggestionPalette = .dark
    let onAdd: (WordSuggestionNode) -> Void
    let onExpand: (WordSuggestionNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(nodes) { node in
                SuggestionNodeRow(
                    node: node,
                    maxDepth: maxDepth,
                    palette: palette,
                    onAdd: onAdd,
                    onExpand: onExpand
                )
            }
        }
    }
}

struct SuggestionNodeRow: View {
    let node: WordSuggestionNode
    let maxDepth: Int
    var palette: SuggestionPalette = .dark
    let onAdd: (WordSuggestionNode) -> Void
    let onExpand: (WordSuggestionNode) -> Void

    private var canExpand: Bool { node.depth < maxDepth }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                addChip
                if canExpand { expandButton }
            }

            if let err = node.errorText {
                Text(err)
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(palette.error)
            }

            if !node.children.isEmpty {
                SuggestionChildrenView(
                    nodes: node.children,
                    maxDepth: maxDepth,
                    palette: palette,
                    onAdd: onAdd,
                    onExpand: onExpand
                )
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(palette.rule)
                        .frame(width: 1)
                }
            }
        }
    }

    // Tapping the chip adds (or, if already added, is a no-op) the word to the
    // save batch. The leading glyph flips from + to a check once added.
    private var addChip: some View {
        Button {
            onAdd(node)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.isAdded ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(node.isAdded ? palette.glyphAdded : palette.glyph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.item.word)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                        .foregroundStyle(palette.primaryText)
                    HStack(spacing: 6) {
                        Text(node.item.translation)
                            .font(.custom("NeueHaasDisplay-Light", size: 11))
                            .foregroundStyle(palette.secondaryText)
                        if let translit = node.item.transliteration, !translit.isEmpty {
                            Text(translit)
                                .font(.system(size: 10))
                                .italic()
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(node.isAdded ? palette.chipFillAdded : palette.chipFill)
            )
            .overlay(
                Capsule().stroke(node.isAdded ? palette.chipStrokeAdded : palette.chipStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var expandButton: some View {
        Button {
            onExpand(node)
        } label: {
            Group {
                if node.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.progressTint)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.expandIcon)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(palette.expandFill))
            .overlay(Circle().stroke(palette.expandStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(node.isLoading || !node.children.isEmpty)
        .opacity(node.children.isEmpty ? 1 : 0.35)
        .accessibilityLabel(Text(L("Suggest related words")))
    }
}
