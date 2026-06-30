import Foundation

extension Character {
    // True for emoji / pictographic characters, including multi-scalar
    // sequences (ZWJ families, flags, skin-tone modifiers, variation
    // selectors). ASCII digits, `#`, and `*` report `isEmoji == true` at
    // the scalar level, so single-scalar characters are only treated as
    // emoji when they either request emoji presentation or sit above the
    // misc-symbols boundary — which excludes those keycap bases.
    var isEmojiLike: Bool {
        guard let first = unicodeScalars.first else { return false }
        if unicodeScalars.count > 1 {
            return unicodeScalars.contains {
                $0.properties.isEmojiPresentation
                    || $0.properties.isJoinControl
                    || $0.value == 0xFE0F            // emoji variation selector
            } || first.properties.isEmoji
        }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && first.value > 0x238C)
    }
}

extension String {
    // Returns the string with emoji removed, collapsing any double spaces
    // the removal leaves behind. Used to keep emoji out of text-to-speech
    // playback and pronunciation grading.
    func strippingEmoji() -> String {
        let filtered = String(filter { !$0.isEmojiLike })
        return filtered
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
