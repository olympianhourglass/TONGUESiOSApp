//
//  LiquidGlassWiperEffect.swift
//  TONGUES
//
//  Animated liquid-glass wiper shader effect.
//
//  Pairing: the `crackGptWiper` Metal function lives in `Shaders.metal`
//  at the target root. Both files must ship together — SwiftUI's
//  `ShaderLibrary` only resolves shaders the Metal compiler built at
//  app-build time, so a shader string in Swift wouldn't work.
//

import SwiftUI

// MARK: - View Modifier

/// Applies the animated liquid-glass wiper shader over the modified view's
/// rendered contents. The shader samples up to ~400px horizontally for the
/// chromatic dispersion, and the content is rasterised via `.drawingGroup()`
/// so the shader receives a clean offscreen pixel buffer.
struct LiquidGlassWiperModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geom in
            TimelineView(.animation) { timeline in
                // Time modded so float precision in the shader stays
                // stable on long-running animations.
                let t = Float(
                    timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1000)
                )
                content
                    .drawingGroup()
                    .layerEffect(
                        ShaderLibrary.crackGptWiper(
                            .float2(Float(geom.size.width),
                                    Float(geom.size.height)),
                            .float(t)
                        ),
                        maxSampleOffset: CGSize(width: 400, height: 0)
                    )
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Wraps this view in the animated liquid-glass wiper effect. Requires
    /// the `crackGptWiper` Metal function in the target's `.metal` source.
    func liquidGlassWiper() -> some View {
        modifier(LiquidGlassWiperModifier())
    }
}

// MARK: - Convenience Wordmark View

/// Self-contained "wordmark on black with liquid-glass wiper" view. Renders
/// the text at high resolution into a UIImage first so the shader samples a
/// crisp pixel buffer, avoiding faint blur artefacts from sampling SwiftUI
/// Text directly.
struct LiquidGlassWordmarkView: View {
    var wordmark: String = "Untitled"
    var fontName: String? = "rocGroteskBoldWide"
    var fontSize: CGFloat = 72

    var body: some View {
        GeometryReader { geom in
            ZStack {
                Color.black
                Image(uiImage: Self.textImage(wordmark: wordmark,
                                                fontName: fontName,
                                                fontSize: fontSize,
                                                size: geom.size))
                    .resizable()
                    .scaledToFit()
            }
            .liquidGlassWiper()
        }
        .ignoresSafeArea()
    }

    private struct CacheKey: Hashable {
        let text: String
        let fontName: String?
        let fontSize: CGFloat
        let size: CGSize
    }
    private static var textImageCache: [CacheKey: UIImage] = [:]

    private static func textImage(wordmark: String,
                                   fontName: String?,
                                   fontSize: CGFloat,
                                   size: CGSize) -> UIImage {
        let key = CacheKey(text: wordmark, fontName: fontName,
                            fontSize: fontSize, size: size)
        if let cached = textImageCache[key] { return cached }

        let format = UIGraphicsImageRendererFormat.default()
        // Fixed 3x — matches the highest native Retina scale shipping
        // today and avoids the iOS 26 deprecation of `UIScreen.main`.
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            let font: UIFont = {
                if let fontName, let f = UIFont(name: fontName, size: fontSize) {
                    return f
                }
                return UIFont.systemFont(ofSize: fontSize, weight: .black)
            }()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .kern: -1.0,
                .paragraphStyle: style,
            ]
            let str = wordmark as NSString
            let textSize = str.size(withAttributes: attrs)
            let origin = CGPoint(x: (size.width - textSize.width) / 2,
                                 y: (size.height - textSize.height) / 2)
            str.draw(at: origin, withAttributes: attrs)
        }
        textImageCache[key] = image
        return image
    }
}

#Preview("Default wordmark") {
    LiquidGlassWordmarkView(wordmark: "Untitled")
}

#Preview("Custom view") {
    ZStack {
        Color.black
        Image(systemName: "sparkles")
            .resizable()
            .scaledToFit()
            .padding(80)
            .foregroundStyle(.white)
    }
    .liquidGlassWiper()
}
