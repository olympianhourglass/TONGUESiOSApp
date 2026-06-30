import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        // Cap each subview's proposed width to the row's max so a
        // long subview (e.g. a single Text token wider than the row,
        // common in CJK or any extra-long token) wraps internally
        // instead of spilling past the row's right edge.
        let subviewProposal = ProposedViewSize(
            width: maxWidth.isFinite ? maxWidth : nil,
            height: nil
        )
        var rowWidths: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]

        for subview in subviews {
            let size = subview.sizeThatFits(subviewProposal)
            let lastIndex = rowWidths.count - 1
            let projected = rowWidths[lastIndex] + (rowWidths[lastIndex] > 0 ? spacing : 0) + size.width
            if projected > maxWidth, rowWidths[lastIndex] > 0 {
                rowWidths.append(size.width)
                rowHeights.append(size.height)
            } else {
                rowWidths[lastIndex] += (rowWidths[lastIndex] > 0 ? spacing : 0) + size.width
                rowHeights[lastIndex] = max(rowHeights[lastIndex], size.height)
            }
        }

        let totalHeight = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        let width = maxWidth.isFinite ? maxWidth : (rowWidths.max() ?? 0)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Same cap as in sizeThatFits — propose the row width to each
        // subview so its placed size matches the wrapped layout we
        // measured (otherwise long Texts get placed at their full
        // single-line width and overflow the bounds).
        let subviewProposal = ProposedViewSize(width: bounds.width, height: nil)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(subviewProposal)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: subviewProposal)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
