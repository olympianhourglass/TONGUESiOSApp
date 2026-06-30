import SwiftUI
import UIKit

// Pre-renders the TONGUES wordmark to a UIImage via UIKit text drawing,
// then exposes a SwiftUI Image so the wordmark composites as a bitmap
// instead of being laid out as glyphs. Bakes in PlayfairDisplay-Regular
// at -8% tracking with generous side padding so the S's trailing
// serifs (and the T's leading serif) can never get clipped at the
// view's edges — the cause of every prior round of "S still cropping".
//
// Tinting via `.renderingMode(.template)` + `.foregroundStyle(...)`
// lets the same cached bitmap flip between white (dark backgrounds)
// and black (light backgrounds) without re-rendering.
@MainActor
private enum TonguesWordmarkRenderer {
    static var cache: [CGFloat: UIImage] = [:]

    static func image(for pointSize: CGFloat) -> UIImage? {
        if let cached = cache[pointSize] { return cached }
        guard let font = UIFont(name: "PlayfairDisplay-Regular", size: pointSize) else {
            return nil
        }
        // -8% tracking matches what the app's Text wordmarks were using
        // (e.g. 32pt * -0.08 = -2.56, the value the splash had).
        let kern: CGFloat = -pointSize * 0.08
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kern,
            // Solid white intentionally — the rendered image goes into
            // .alwaysTemplate mode below, which discards RGB and uses
            // the alpha mask + the SwiftUI tint color. So the source
            // color only needs to be opaque.
            .foregroundColor: UIColor.white
        ]
        let attributed = NSAttributedString(string: "TONGUES", attributes: attributes)
        let textSize = attributed.size()

        // Symmetric side padding clears the T's leading serif and the
        // S's trailing serif. 25% of the font size is overkill for
        // both, which is fine — we'd rather a safe margin than a
        // sliver-clip relapse.
        let sidePad = pointSize * 0.25
        let canvasSize = CGSize(
            width: ceil(textSize.width + sidePad * 2),
            height: ceil(textSize.height)
        )

        // 3x scale gives crisp output on retina without forcing the
        // caller to mark the SwiftUI Image as resizable.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let rendered = renderer.image { _ in
            attributed.draw(at: CGPoint(x: sidePad, y: 0))
        }
        let templated = rendered.withRenderingMode(.alwaysTemplate)
        cache[pointSize] = templated
        return templated
    }
}

// SwiftUI wrapper. Drop-in replacement for `Text("TONGUES")` at any
// of the wordmark sites. The caller controls the color via the
// standard `.foregroundStyle(...)` modifier.
struct TonguesWordmark: View {
    let size: CGFloat

    var body: some View {
        if let image = TonguesWordmarkRenderer.image(for: size) {
            Image(uiImage: image)
        } else {
            // Graceful fallback if the font fails to load. Uses the
            // same tracking math as the image so the layout stays
            // close even on the fallback path.
            Text("TONGUES")
                .font(.custom("PlayfairDisplay-Regular", size: size))
                .tracking(-size * 0.08)
        }
    }
}
