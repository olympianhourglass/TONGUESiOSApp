import CoreGraphics
import Foundation

// Per-jamo stroke medians (normalized to a [0,1] unit box, y-down, with
// stroke order + direction preserved) plus the composition logic that lays
// a syllable block's jamo out and concatenates their strokes in writing
// order. This lets Korean flow through the same StrokeMatcher pipeline as
// Chinese and Japanese instead of falling back to template tracing.
//
// The coordinates are hand-authored approximations. That's fine: StrokeMatcher
// judges start/end position, direction, and gross shape with generous finger-
// input tolerances, so a geometrically reasonable median validates real
// handwriting without needing font-perfect outlines.
enum HangulStrokeData {
    // Base jamo we carry medians for. Tense doubles + final clusters are
    // decomposed into these (see `components`).
    static let jamo: [Character: [[CGPoint]]] = build([
        // Consonants
        "ㄱ": [[(0.18, 0.22), (0.82, 0.20), (0.64, 0.86)]],
        "ㄴ": [[(0.28, 0.16), (0.28, 0.80), (0.84, 0.80)]],
        "ㄷ": [[(0.20, 0.22), (0.80, 0.22)], [(0.22, 0.24), (0.22, 0.80), (0.82, 0.80)]],
        "ㄹ": [[(0.22, 0.20), (0.80, 0.20)], [(0.80, 0.20), (0.28, 0.50), (0.80, 0.50)], [(0.22, 0.50), (0.22, 0.82), (0.82, 0.82)]],
        "ㅁ": [[(0.26, 0.20), (0.26, 0.82)], [(0.26, 0.20), (0.80, 0.20), (0.80, 0.82)], [(0.26, 0.82), (0.80, 0.82)]],
        "ㅂ": [[(0.28, 0.16), (0.28, 0.84)], [(0.74, 0.16), (0.74, 0.84)], [(0.28, 0.52), (0.74, 0.52)], [(0.28, 0.84), (0.74, 0.84)]],
        "ㅅ": [[(0.50, 0.20), (0.24, 0.84)], [(0.52, 0.42), (0.82, 0.84)]],
        "ㅇ": [[(0.50, 0.16), (0.74, 0.26), (0.84, 0.50), (0.74, 0.74), (0.50, 0.84), (0.26, 0.74), (0.16, 0.50), (0.26, 0.26), (0.50, 0.16)]],
        "ㅈ": [[(0.22, 0.24), (0.78, 0.24)], [(0.50, 0.24), (0.26, 0.84)], [(0.52, 0.44), (0.80, 0.84)]],
        "ㅊ": [[(0.42, 0.10), (0.60, 0.10)], [(0.22, 0.30), (0.78, 0.30)], [(0.50, 0.30), (0.26, 0.86)], [(0.52, 0.48), (0.80, 0.86)]],
        "ㅋ": [[(0.18, 0.22), (0.82, 0.20), (0.66, 0.86)], [(0.30, 0.50), (0.80, 0.50)]],
        "ㅌ": [[(0.22, 0.20), (0.80, 0.20)], [(0.22, 0.50), (0.80, 0.50)], [(0.22, 0.20), (0.22, 0.82), (0.82, 0.82)]],
        "ㅍ": [[(0.16, 0.26), (0.84, 0.26)], [(0.34, 0.28), (0.32, 0.80)], [(0.66, 0.28), (0.68, 0.80)], [(0.16, 0.82), (0.84, 0.82)]],
        "ㅎ": [[(0.40, 0.10), (0.60, 0.10)], [(0.22, 0.32), (0.78, 0.32)], [(0.50, 0.44), (0.68, 0.52), (0.60, 0.72), (0.40, 0.74), (0.32, 0.54), (0.50, 0.44)]],
        // Vowels
        "ㅣ": [[(0.50, 0.08), (0.50, 0.92)]],
        "ㅏ": [[(0.45, 0.08), (0.45, 0.92)], [(0.45, 0.50), (0.85, 0.50)]],
        "ㅑ": [[(0.45, 0.08), (0.45, 0.92)], [(0.45, 0.34), (0.85, 0.34)], [(0.45, 0.62), (0.85, 0.62)]],
        "ㅓ": [[(0.12, 0.50), (0.55, 0.50)], [(0.55, 0.08), (0.55, 0.92)]],
        "ㅕ": [[(0.12, 0.34), (0.55, 0.34)], [(0.12, 0.62), (0.55, 0.62)], [(0.55, 0.08), (0.55, 0.92)]],
        "ㅐ": [[(0.40, 0.08), (0.40, 0.92)], [(0.40, 0.50), (0.66, 0.50)], [(0.80, 0.08), (0.80, 0.92)]],
        "ㅒ": [[(0.34, 0.08), (0.34, 0.92)], [(0.34, 0.34), (0.60, 0.34)], [(0.34, 0.62), (0.60, 0.62)], [(0.78, 0.08), (0.78, 0.92)]],
        "ㅔ": [[(0.12, 0.50), (0.38, 0.50)], [(0.40, 0.08), (0.40, 0.92)], [(0.80, 0.08), (0.80, 0.92)]],
        "ㅖ": [[(0.12, 0.34), (0.38, 0.34)], [(0.12, 0.62), (0.38, 0.62)], [(0.40, 0.08), (0.40, 0.92)], [(0.80, 0.08), (0.80, 0.92)]],
        "ㅗ": [[(0.50, 0.14), (0.50, 0.58)], [(0.10, 0.76), (0.90, 0.76)]],
        "ㅛ": [[(0.36, 0.14), (0.36, 0.58)], [(0.64, 0.14), (0.64, 0.58)], [(0.10, 0.76), (0.90, 0.76)]],
        "ㅜ": [[(0.10, 0.42), (0.90, 0.42)], [(0.50, 0.42), (0.50, 0.86)]],
        "ㅠ": [[(0.10, 0.42), (0.90, 0.42)], [(0.36, 0.42), (0.36, 0.86)], [(0.64, 0.42), (0.64, 0.86)]],
        "ㅡ": [[(0.10, 0.50), (0.90, 0.50)]],
        "ㅢ": [[(0.08, 0.50), (0.66, 0.50)], [(0.82, 0.10), (0.82, 0.90)]],
        "ㅚ": [[(0.34, 0.18), (0.34, 0.56)], [(0.10, 0.66), (0.56, 0.66)], [(0.80, 0.08), (0.80, 0.92)]],
        "ㅘ": [[(0.30, 0.16), (0.30, 0.50)], [(0.08, 0.60), (0.50, 0.60)], [(0.68, 0.08), (0.68, 0.92)], [(0.68, 0.50), (0.95, 0.50)]],
        "ㅙ": [[(0.28, 0.16), (0.28, 0.50)], [(0.08, 0.60), (0.48, 0.60)], [(0.64, 0.08), (0.64, 0.92)], [(0.64, 0.50), (0.84, 0.50)], [(0.92, 0.08), (0.92, 0.92)]],
        "ㅝ": [[(0.08, 0.42), (0.50, 0.42)], [(0.30, 0.42), (0.30, 0.86)], [(0.56, 0.50), (0.72, 0.50)], [(0.72, 0.08), (0.72, 0.92)]],
        "ㅞ": [[(0.08, 0.42), (0.46, 0.42)], [(0.28, 0.42), (0.28, 0.86)], [(0.52, 0.50), (0.66, 0.50)], [(0.66, 0.08), (0.66, 0.92)], [(0.86, 0.08), (0.86, 0.92)]],
        "ㅟ": [[(0.08, 0.42), (0.50, 0.42)], [(0.30, 0.42), (0.30, 0.86)], [(0.80, 0.08), (0.80, 0.92)]],
    ])

    // Tense doubles + final clusters, decomposed into base jamo drawn side by
    // side within the assigned block region.
    static let components: [Character: [Character]] = [
        "ㄲ": ["ㄱ", "ㄱ"], "ㄸ": ["ㄷ", "ㄷ"], "ㅃ": ["ㅂ", "ㅂ"], "ㅆ": ["ㅅ", "ㅅ"], "ㅉ": ["ㅈ", "ㅈ"],
        "ㄳ": ["ㄱ", "ㅅ"], "ㄵ": ["ㄴ", "ㅈ"], "ㄶ": ["ㄴ", "ㅎ"], "ㄺ": ["ㄹ", "ㄱ"], "ㄻ": ["ㄹ", "ㅁ"],
        "ㄼ": ["ㄹ", "ㅂ"], "ㄽ": ["ㄹ", "ㅅ"], "ㄾ": ["ㄹ", "ㅌ"], "ㄿ": ["ㄹ", "ㅍ"], "ㅀ": ["ㄹ", "ㅎ"], "ㅄ": ["ㅂ", "ㅅ"],
    ]

    private static func build(_ raw: [Character: [[(Double, Double)]]]) -> [Character: [[CGPoint]]] {
        var out: [Character: [[CGPoint]]] = [:]
        for (ch, strokes) in raw {
            out[ch] = strokes.map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
        }
        return out
    }
}

// Composes a precomposed Hangul syllable into ordered stroke medians in the
// same normalized [0,1] block space StrokeDataStore hands the CJK matcher.
enum HangulComposer {
    private struct Box { let x, y, w, h: CGFloat }
    private enum Orientation { case right, bottom, mixed }

    // Returns nil for anything that isn't a fully-renderable Hangul syllable,
    // so the caller cleanly falls back to template tracing.
    static func compose(_ syllable: Character) -> [[CGPoint]]? {
        guard let parts = Hangul.decompose(syllable), parts.count >= 2,
              let initial = parts[0].first,
              let medial = parts[1].first else { return nil }
        let final = parts.count > 2 ? parts[2].first : nil

        guard renderable(initial), renderable(medial), final.map(renderable) ?? true else {
            return nil
        }

        let orient = orientation(of: medial)
        let (iBox, mBox, fBox) = layout(orient, hasFinal: final != nil)

        var strokes: [[CGPoint]] = []
        strokes += placed(initial, in: iBox)
        strokes += placed(medial, in: mBox)
        if let f = final, let fb = fBox { strokes += placed(f, in: fb) }
        return strokes.isEmpty ? nil : strokes
    }

    private static func renderable(_ jamo: Character) -> Bool {
        if HangulStrokeData.jamo[jamo] != nil { return true }
        if let comps = HangulStrokeData.components[jamo] {
            return comps.allSatisfy { HangulStrokeData.jamo[$0] != nil }
        }
        return false
    }

    // Maps a jamo's unit-box medians into a block-space box. Doubles/clusters
    // are split into side-by-side halves so both components are drawn.
    private static func placed(_ jamo: Character, in box: Box) -> [[CGPoint]] {
        if let strokes = HangulStrokeData.jamo[jamo] {
            return strokes.map { $0.map { map($0, into: box) } }
        }
        guard let comps = HangulStrokeData.components[jamo] else { return [] }
        let gap = box.w * 0.08
        let halfW = (box.w - gap) / 2
        let left = Box(x: box.x, y: box.y, w: halfW, h: box.h)
        let right = Box(x: box.x + halfW + gap, y: box.y, w: halfW, h: box.h)
        var out: [[CGPoint]] = []
        if let a = HangulStrokeData.jamo[comps[0]] {
            out += a.map { $0.map { map($0, into: left) } }
        }
        if comps.count > 1, let b = HangulStrokeData.jamo[comps[1]] {
            out += b.map { $0.map { map($0, into: right) } }
        }
        return out
    }

    private static func map(_ p: CGPoint, into b: Box) -> CGPoint {
        CGPoint(x: b.x + p.x * b.w, y: b.y + p.y * b.h)
    }

    private static func orientation(of medial: Character) -> Orientation {
        let right: Set<Character> = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅣ"]
        let bottom: Set<Character> = ["ㅗ", "ㅛ", "ㅜ", "ㅠ", "ㅡ"]
        if right.contains(medial) { return .right }
        if bottom.contains(medial) { return .bottom }
        return .mixed
    }

    // Block-space regions for (initial, medial, optional final), keyed by the
    // medial vowel's orientation and whether the syllable has a batchim.
    private static func layout(_ o: Orientation, hasFinal: Bool) -> (Box, Box, Box?) {
        switch (o, hasFinal) {
        case (.right, false):
            return (Box(x: 0.05, y: 0.14, w: 0.44, h: 0.72), Box(x: 0.55, y: 0.06, w: 0.40, h: 0.88), nil)
        case (.right, true):
            return (Box(x: 0.05, y: 0.06, w: 0.42, h: 0.50), Box(x: 0.52, y: 0.04, w: 0.42, h: 0.54), Box(x: 0.12, y: 0.62, w: 0.64, h: 0.34))
        case (.bottom, false):
            return (Box(x: 0.22, y: 0.06, w: 0.56, h: 0.40), Box(x: 0.06, y: 0.50, w: 0.88, h: 0.44), nil)
        case (.bottom, true):
            return (Box(x: 0.24, y: 0.04, w: 0.52, h: 0.30), Box(x: 0.06, y: 0.36, w: 0.88, h: 0.30), Box(x: 0.24, y: 0.68, w: 0.52, h: 0.30))
        case (.mixed, false):
            return (Box(x: 0.05, y: 0.06, w: 0.40, h: 0.44), Box(x: 0.05, y: 0.05, w: 0.92, h: 0.90), nil)
        case (.mixed, true):
            return (Box(x: 0.05, y: 0.04, w: 0.36, h: 0.38), Box(x: 0.05, y: 0.03, w: 0.92, h: 0.62), Box(x: 0.16, y: 0.66, w: 0.62, h: 0.30))
        }
    }
}
