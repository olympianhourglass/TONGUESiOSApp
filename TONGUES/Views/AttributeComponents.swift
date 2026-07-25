import SwiftUI

struct InterestChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 14))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSelected ? Color.black : Color(white: 0.85),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct AttributesRow: View {
    let language: String
    let dialect: String
    let content: String
    let amount: String
    let level: String
    let onTap: (DeckAttribute) -> Void
    // Non-nil only on the Create New Deck generate form, where the
    // first-run coach tour needs each pill's position. Pills publish their
    // STATIC frame in the content coordinate space declared below; the tour
    // combines that with the strip's live scroll offset to compute where
    // each pill currently sits on screen.
    var coachStore: CoachFrameStore? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            attribute(.language, value: language)
            attribute(.dialect, value: dialect)
            attribute(.content, value: content)
            attribute(.amount, value: amount)
            attribute(.level, value: level)
        }
        // The scroll content's own coordinate space — pill frames measured
        // in here are scroll-independent (see CoachContentSpace).
        .coordinateSpace(.named(CoachContentSpace.name))
    }

    private func attribute(_ kind: DeckAttribute, value: String) -> some View {
        Button {
            Haptics.light()
            onTap(kind)
        } label: {
            // Label + current selection sit on a single line: the label
            // in the darker medium weight, the selected value in a lighter
            // opacity so it reads as secondary.
            HStack(spacing: 6) {
                Text(L(kind.title))
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.black)
                Text(localizedAttributeValue(value, for: kind))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.black.opacity(0.4))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
            // Publishes the pill's frame for the first-run coach tour.
            .coachAnchorIf(coachTarget(for: kind), store: coachStore)
        }
        .buttonStyle(.plain)
        // Lets the coach tour scroll this pill into view by attribute id.
        .id(kind)
    }

    private func coachTarget(for kind: DeckAttribute) -> CoachTarget? {
        switch kind {
        case .language: return .language
        case .dialect:  return .dialect
        case .content:  return .content
        case .amount:   return .amount
        case .level:    return .level
        }
    }
}

struct ToneLabel: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 36))
                .foregroundStyle(isSelected ? Color.black : Color(white: 0.75))
        }
        .buttonStyle(.plain)
    }
}
