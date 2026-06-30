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
                            isSelected ? Color.red : Color(white: 0.85),
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
        HStack(alignment: .top, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.custom("NeueHaasDisplay-Light", size: 12))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                Haptics.light()
                onTap(kind)
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
                // Publishes the pill's frame for the first-run coach tour.
                .coachAnchorIf(coachTarget(for: kind), store: coachStore)
            }
            .buttonStyle(.plain)
        }
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
                .font(.custom("NeueHaasDisplay-Mediu", size: 40))
                .foregroundStyle(isSelected ? Color.black : Color(white: 0.75))
        }
        .buttonStyle(.plain)
    }
}
