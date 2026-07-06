import CoreGraphics
import UIKit
import Vision

// Trace-the-template engine for Korean + Arabic. We render the target word
// once (contextual shaping + RTL handled by UIKit/CoreText), show it faintly
// as a tracing guide, and score the user's ink by how well it overlaps that
// rendered glyph — recall (did they cover the glyph?) and precision (did they
// stay on it?). Deterministic + offline; an optional Vision OCR pass can
// upgrade a borderline trace.

/// A rendered target word: a faint display image plus a luminance mask used
/// for coverage math. Both come from the SAME layout pass, so the on-screen
/// guide and the scoring grid are pixel-aligned.
struct TemplateGlyph {
    let text: String
    let script: HandwritingScript
    let displayImage: UIImage          // dark glyph on clear — shown faintly
    private let mask: [UInt8]           // luminance 0…255 at mask resolution
    private let dilated: [UInt8]        // mask grown by a tolerance radius
    let maskWidth: Int
    let maskHeight: Int
    let pointSize: CGSize               // the rect this was laid out for

    // Indices of "glyph" pixels for quick recall math.
    private let coreIndices: [Int]

    static func render(text: String, script: HandwritingScript, in size: CGSize) -> TemplateGlyph? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, size.width > 1, size.height > 1 else { return nil }

        // Mask resolution: cap the long side so coverage math stays cheap.
        let longSide = max(size.width, size.height)
        let scale = min(1.0, 150.0 / longSide)
        let mw = max(8, Int((size.width * scale).rounded()))
        let mh = max(8, Int((size.height * scale).rounded()))

        let font = fittedFont(for: word, script: script, in: CGSize(width: mw, height: mh))

        // Two renders, identical geometry: dark-on-clear for display, and
        // white-on-black for the luminance mask.
        let display = renderText(word, script: script, font: font,
                                 pixel: CGSize(width: mw, height: mh),
                                 color: UIColor(white: 0.0, alpha: 1),
                                 opaque: false)
        guard let maskImage = renderText(word, script: script, font: font,
                                         pixel: CGSize(width: mw, height: mh),
                                         color: .white, opaque: true).cgImage,
              let displayCG = display.cgImage
        else { return nil }

        let lum = luminanceBuffer(from: maskImage, width: mw, height: mh)
        let radius = max(2, Int((Double(mh) / 16.0).rounded()))
        let dil = dilate(lum, width: mw, height: mh, radius: radius, threshold: 60)
        var core: [Int] = []
        for i in 0..<lum.count where lum[i] > 60 { core.append(i) }
        guard !core.isEmpty else { return nil }

        return TemplateGlyph(
            text: word, script: script,
            displayImage: UIImage(cgImage: displayCG),
            mask: lum, dilated: dil,
            maskWidth: mw, maskHeight: mh,
            pointSize: size, coreIndices: core
        )
    }

    struct Coverage {
        let recall: Double       // fraction of the glyph the user traced
        let precision: Double    // fraction of ink that landed on the glyph
        let passed: Bool
    }

    /// Score user ink (view-coordinate strokes within `rect`) against this glyph.
    func evaluate(userStrokes: [[CGPoint]], rect: CGRect,
                  recallGoal: Double = 0.5, precisionGoal: Double = 0.34) -> Coverage {
        let ink = rasterizeInk(userStrokes, rect: rect)
        guard !ink.isEmpty else {
            return Coverage(recall: 0, precision: 0, passed: false)
        }
        var covered = 0
        for i in coreIndices where ink[i] > 0 { covered += 1 }
        let recall = Double(covered) / Double(coreIndices.count)

        var inkTotal = 0, inkOnGlyph = 0
        for i in 0..<ink.count where ink[i] > 0 {
            inkTotal += 1
            if dilated[i] > 0 { inkOnGlyph += 1 }
        }
        let precision = inkTotal == 0 ? 0 : Double(inkOnGlyph) / Double(inkTotal)
        return Coverage(recall: recall, precision: precision,
                        passed: recall >= recallGoal && precision >= precisionGoal)
    }

    // Rasterize the user's ink into the mask grid.
    private func rasterizeInk(_ strokes: [[CGPoint]], rect: CGRect) -> [UInt8] {
        let mw = maskWidth, mh = maskHeight
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: mw, height: mh), format: fmt)
        let sx = CGFloat(mw) / rect.width
        let sy = CGFloat(mh) / rect.height
        let lineW = max(2.0, CGFloat(mh) * 0.09)
        let img = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(lineW)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes where stroke.count > 0 {
                let mapped = stroke.map { p in
                    CGPoint(x: (p.x - rect.minX) * sx, y: (p.y - rect.minY) * sy)
                }
                if mapped.count == 1 {
                    let p = mapped[0]
                    cg.fillEllipse(in: CGRect(x: p.x - lineW / 2, y: p.y - lineW / 2,
                                              width: lineW, height: lineW))
                } else {
                    cg.beginPath()
                    cg.addLines(between: mapped)
                    cg.strokePath()
                }
            }
        }
        guard let cg = img.cgImage else { return [] }
        return TemplateGlyph.luminanceBuffer(from: cg, width: mw, height: mh)
    }

    // MARK: Rendering helpers

    private static func attributed(_ text: String, script: HandwritingScript,
                                   font: UIFont, color: UIColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.baseWritingDirection = script.isRightToLeft ? .rightToLeft : .leftToRight
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
    }

    private static func fittedFont(for text: String, script: HandwritingScript,
                                   in pixel: CGSize) -> UIFont {
        let padding: CGFloat = 0.16
        let avail = CGSize(width: pixel.width * (1 - 2 * padding),
                           height: pixel.height * (1 - 2 * padding))
        var size = pixel.height * 0.8
        let probe = attributed(text, script: script,
                               font: .systemFont(ofSize: size, weight: .regular), color: .black)
        let measured = probe.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin], context: nil).size
        let factor = min(avail.width / max(measured.width, 1),
                         avail.height / max(measured.height, 1))
        size = max(8, size * factor)
        return .systemFont(ofSize: size, weight: .regular)
    }

    private static func renderText(_ text: String, script: HandwritingScript,
                                   font: UIFont, pixel: CGSize,
                                   color: UIColor, opaque: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = opaque
        let renderer = UIGraphicsImageRenderer(size: pixel, format: fmt)
        let attr = attributed(text, script: script, font: font, color: color)
        let textSize = attr.boundingRect(with: CGSize(width: pixel.width,
                                                       height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil).size
        return renderer.image { ctx in
            if opaque {
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: pixel))
            }
            let origin = CGPoint(x: (pixel.width - textSize.width) / 2,
                                 y: (pixel.height - textSize.height) / 2)
            attr.draw(with: CGRect(origin: origin, size: textSize),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    fileprivate static func luminanceBuffer(from image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private static func dilate(_ src: [UInt8], width: Int, height: Int,
                               radius: Int, threshold: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                if src[y * width + x] <= threshold { continue }
                for dy in -radius...radius {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -radius...radius {
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        out[ny * width + nx] = 255
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Optional Vision OCR cross-check

enum HandwritingOCR {
    /// Best-effort: render the ink and ask Vision what it reads. Used only to
    /// upgrade a borderline trace, never to reject one. Arabic recognition is
    /// limited on-device, so a nil/empty result is expected and harmless.
    static func recognize(strokes: [[CGPoint]], rect: CGRect,
                          script: HandwritingScript) async -> [String] {
        guard !strokes.isEmpty else { return [] }
        let size = CGSize(width: max(rect.width, 32), height: max(rect.height, 32))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 2
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(max(3, size.height * 0.06))
            cg.setLineCap(.round); cg.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                cg.beginPath()
                cg.addLines(between: stroke.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) })
                cg.strokePath()
            }
        }
        guard let cg = img.cgImage else { return [] }

        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let results = (req.results as? [VNRecognizedTextObservation]) ?? []
                let strings = results.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: strings)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            switch script {
            case .korean: request.recognitionLanguages = ["ko-KR"]
            case .arabic: request.recognitionLanguages = ["ar-SA", "ar"]
            default: break
            }
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { cont.resume(returning: []) }
            }
        }
    }
}

// MARK: - Hangul composition (for Korean hints)

enum Hangul {
    private static let initials = ["ㄱ","ㄲ","ㄴ","ㄷ","ㄸ","ㄹ","ㅁ","ㅂ","ㅃ","ㅅ","ㅆ","ㅇ","ㅈ","ㅉ","ㅊ","ㅋ","ㅌ","ㅍ","ㅎ"]
    private static let medials = ["ㅏ","ㅐ","ㅑ","ㅒ","ㅓ","ㅔ","ㅕ","ㅖ","ㅗ","ㅘ","ㅙ","ㅚ","ㅛ","ㅜ","ㅝ","ㅞ","ㅟ","ㅠ","ㅡ","ㅢ","ㅣ"]
    private static let finals = ["","ㄱ","ㄲ","ㄳ","ㄴ","ㄵ","ㄶ","ㄷ","ㄹ","ㄺ","ㄻ","ㄼ","ㄽ","ㄾ","ㄿ","ㅀ","ㅁ","ㅂ","ㅄ","ㅅ","ㅆ","ㅇ","ㅈ","ㅊ","ㅋ","ㅌ","ㅍ","ㅎ"]

    /// Decompose a precomposed Hangul syllable into its jamo (initial, medial,
    /// optional final). Returns nil for non-syllable characters.
    static func decompose(_ ch: Character) -> [String]? {
        guard let scalar = ch.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let s = Int(scalar.value) - 0xAC00
        let ini = s / (21 * 28)
        let med = (s % (21 * 28)) / 28
        let fin = s % 28
        var parts = [initials[ini], medials[med]]
        if fin > 0 { parts.append(finals[fin]) }
        return parts
    }

    /// A "ㅎ + ㅏ + ㄴ" style breakdown of a whole word, used as a text hint.
    static func breakdown(_ word: String) -> String {
        word.compactMap { ch -> String? in
            guard let parts = decompose(ch) else { return nil }
            return parts.joined(separator: " + ")
        }.joined(separator: "   ")
    }
}
