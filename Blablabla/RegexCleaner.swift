import Foundation

/// Cheap deterministic filler-word remover for Russian voice transcripts.
/// No model, no allocations beyond the result string. Microseconds per call.
///
/// Strategy:
/// - "strong" fillers — discourse markers that are ~always meaningless ("ну",
///   "короче", "типа", "значит", interjections). Stripped wherever they appear
///   between sentence/comma boundaries.
/// - "edge-only" fillers — words that ARE meaningful in some contexts ("так"
///   in "так что", "вот" in "вот этот стол"). Stripped only at the very start
///   of the utterance or right after a period.
enum RegexCleaner {
    private static let strong: [String] = [
        "ну", "короче", "типа", "значит", "эм", "э-э", "м-м", "ага", "ой",
        "как бы", "это самое",
    ]

    private static let edgeOnly: [String] = [
        "так", "вот", "в общем",
    ]

    static func clean(_ text: String) -> String {
        var s = text

        // 1) Compound filler "Ну, то есть," — match before generic patterns.
        s = sub(s, #"\b[Нн]у,?\s+то\s+есть,?\s+"#, "")

        // 2) Strip a leading sequence of fillers (start of utterance).
        let edgeAlt = (strong + edgeOnly).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        s = sub(s, #"^(?:(?:"# + edgeAlt + #")[,]?\s+)+"#, "")

        // 3) Strip filler sequences right after sentence-ending punctuation.
        s = sub(s, #"([\.\!\?])\s+(?:(?:"# + edgeAlt + #")[,]?\s+)+"#, "$1 ")

        // 4) Strip "strong" fillers wedged between commas. NOT edge-only here so
        //    we don't mangle "вот этот стол", "так что не надо".
        let strongAlt = strong.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        s = sub(s, #",\s+(?:(?:"# + strongAlt + #")[,]?\s+)+"#, ", ")

        // 5) Whitespace cleanup + spaces before punctuation.
        s = sub(s, #"[ \t]+"#, " ")
        s = sub(s, #"\s+([,\.\?\!])"#, "$1")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 6) Capitalize first letter if cleanup left it lowercased.
        if let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }

        return s
    }

    private static func sub(_ s: String, _ pattern: String, _ replacement: String) -> String {
        s.replacingOccurrences(
            of: pattern, with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
