import CoreGraphics
import Foundation

// Loads the bundled per-character stroke-median datasets and hands back
// normalized stroke polylines for a requested character.
//
// Dataset format (see Resources/HandwritingStrokes/*.json, built from
// hanzi-writer-data / hanzi-writer-data-jp / KanjiVG): a JSON object keyed
// by character; each value is a list of strokes; each stroke is a list of
// [x, y] points already normalized to [0, 1] in SCREEN space (origin
// top-left, y pointing DOWN, stroke order + direction preserved).
final class StrokeDataStore {
    static let shared = StrokeDataStore()

    private var cache: [HandwritingScript: [String: [[CGPoint]]]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Median strokes for a single character in the given script, or nil when
    /// the character isn't in the bundled subset. Points are in [0,1] space.
    func strokes(for character: Character, script: HandwritingScript) -> [[CGPoint]]? {
        guard script.tier == .strokeMatch else { return nil }
        let table = dataset(for: script)
        return table[String(character)]
    }

    /// True when every non-whitespace character of `word` has bundled data.
    func hasFullCoverage(for word: String, script: HandwritingScript) -> Bool {
        let chars = word.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return false }
        let table = dataset(for: script)
        return chars.allSatisfy { table[String($0)] != nil }
    }

    /// Characters of `word` that we can drive stroke-matching for, in order.
    func practicableCharacters(in word: String, script: HandwritingScript) -> [Character] {
        let table = dataset(for: script)
        return word.filter { !$0.isWhitespace && table[String($0)] != nil }
    }

    private func dataset(for script: HandwritingScript) -> [String: [[CGPoint]]] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[script] { return cached }
        let loaded = Self.load(resource: resourceName(for: script))
        cache[script] = loaded
        return loaded
    }

    private func resourceName(for script: HandwritingScript) -> String {
        switch script {
        case .chinese:  return "chinese"
        case .japanese: return "japanese"
        default:        return ""   // template scripts have no median data
        }
    }

    // MARK: On-demand coverage (Hanzi Writer CDN + disk cache)

    /// Ensures every character of `word` has stroke data, fetching any
    /// missing ones from the Hanzi Writer open dataset (cached to disk
    /// after the first fetch). Returns true once the whole word is
    /// covered. Any network/parse failure degrades gracefully to false,
    /// so the caller falls back to template tracing — never an error.
    @discardableResult
    func ensureCoverage(for word: String, script: HandwritingScript) async -> Bool {
        guard script.tier == .strokeMatch else { return false }
        let chars = Set(word.filter { !$0.isWhitespace })
        guard !chars.isEmpty else { return false }
        for character in chars where strokes(for: character, script: script) == nil {
            if let cached = loadFromDisk(character, script: script) {
                insert(cached, for: character, script: script)
            } else if let fetched = await fetchFromCDN(character, script: script) {
                insert(fetched, for: character, script: script)
                saveToDisk(fetched, for: character, script: script)
            }
        }
        return hasFullCoverage(for: word, script: script)
    }

    private func insert(_ strokes: [[CGPoint]], for character: Character, script: HandwritingScript) {
        _ = dataset(for: script)   // make sure the bundled table is loaded first
        lock.lock(); defer { lock.unlock() }
        cache[script]?[String(character)] = strokes
    }

    private func cdnPackage(for script: HandwritingScript) -> String? {
        switch script {
        case .chinese:  return "hanzi-writer-data@2"
        case .japanese: return "hanzi-writer-data-jp@1"
        default:        return nil
        }
    }

    private func fetchFromCDN(_ character: Character, script: HandwritingScript) async -> [[CGPoint]]? {
        guard let package = cdnPackage(for: script),
              let encoded = String(character).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://cdn.jsdelivr.net/npm/\(package)/\(encoded).json")
        else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Self.decodeMedians(data)
        } catch {
            return nil
        }
    }

    // Hanzi Writer files carry stroke medians on a 1024×1024 grid with the
    // Y axis pointing UP. Normalize to [0,1] and flip Y so they match the
    // bundled data's screen space (origin top-left, y-down). Stroke order
    // and per-stroke direction are preserved.
    private static func decodeMedians(_ data: Data) -> [[CGPoint]]? {
        struct HanziWriterChar: Decodable { let medians: [[[Double]]] }
        guard let decoded = try? JSONDecoder().decode(HanziWriterChar.self, from: data),
              !decoded.medians.isEmpty else { return nil }
        return decoded.medians.map { stroke in
            stroke.compactMap { pair -> CGPoint? in
                guard pair.count == 2 else { return nil }
                return CGPoint(x: pair[0] / 1024.0, y: (1024.0 - pair[1]) / 1024.0)
            }
        }
    }

    private func diskURL(for character: Character, script: HandwritingScript) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let scalar = character.unicodeScalars.first?.value else { return nil }
        return base
            .appendingPathComponent("HandwritingStrokes/\(script.rawValue)", isDirectory: true)
            .appendingPathComponent(String(format: "%X.json", scalar))
    }

    private func loadFromDisk(_ character: Character, script: HandwritingScript) -> [[CGPoint]]? {
        guard let url = diskURL(for: character, script: script),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return nil }
        return raw.map { $0.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
    }

    private func saveToDisk(_ strokes: [[CGPoint]], for character: Character, script: HandwritingScript) {
        guard let url = diskURL(for: character, script: script) else { return }
        let raw = strokes.map { $0.map { [Double($0.x), Double($0.y)] } }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func load(resource: String) -> [String: [[CGPoint]]] {
        guard !resource.isEmpty,
              let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [[[Double]]]].self, from: data)
        else { return [:] }

        var out: [String: [[CGPoint]]] = [:]
        out.reserveCapacity(raw.count)
        for (char, strokes) in raw {
            out[char] = strokes.map { stroke in
                stroke.compactMap { pair in
                    pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
                }
            }
        }
        return out
    }
}

// Geometry helper: fit a character's normalized strokes (which can slightly
// exceed [0,1] because of descenders) into a target rect, preserving aspect
// ratio and centering. Used by both the faint guide and the stroke matcher
// so screen geometry and validation geometry stay identical.
struct CharacterLayout {
    let strokes: [[CGPoint]]        // normalized [0,1], y-down
    let rect: CGRect                // destination rect in view coordinates

    private let scale: CGFloat
    private let offset: CGPoint

    init(strokes: [[CGPoint]], in rect: CGRect, padding: CGFloat = 0.08) {
        self.strokes = strokes
        self.rect = rect

        let all = strokes.flatMap { $0 }
        let minX = all.map(\.x).min() ?? 0
        let maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? 0
        let maxY = all.map(\.y).max() ?? 1
        let w = max(maxX - minX, 0.0001)
        let h = max(maxY - minY, 0.0001)

        let inset = rect.insetBy(dx: rect.width * padding, dy: rect.height * padding)
        let s = min(inset.width / w, inset.height / h)
        self.scale = s
        // Center the scaled bbox inside `inset`.
        let drawnW = w * s
        let drawnH = h * s
        self.offset = CGPoint(
            x: inset.minX + (inset.width - drawnW) / 2 - minX * s,
            y: inset.minY + (inset.height - drawnH) / 2 - minY * s
        )
    }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale)
    }

    /// A stroke's median mapped into view coordinates.
    func viewStroke(_ index: Int) -> [CGPoint] {
        guard strokes.indices.contains(index) else { return [] }
        return strokes[index].map(point)
    }

    var viewStrokes: [[CGPoint]] {
        strokes.map { $0.map(point) }
    }
}
