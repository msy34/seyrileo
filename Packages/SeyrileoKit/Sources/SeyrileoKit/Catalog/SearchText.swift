import Foundation

/// Search normalization tuned for Turkish channel names typed on any keyboard.
///
/// - Case-insensitive, including the Turkish dotted/dotless I family (`I ı İ i` all → `i`),
///   so "BEIN", "beın" and "bein" match.
/// - Diacritic-insensitive (`ç ğ ö ş ü` → `c g o s u`), so "cagri" finds "Çağrı".
/// - Punctuation becomes word separators ("|TR| Trt-1" → "tr trt 1").
public enum SearchText {
    public static func normalize(_ text: String) -> String {
        let dotless = text
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
        let folded = dotless.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        return tokens(inNormalized: folded).joined(separator: " ")
    }

    /// FTS5 MATCH expression: every word must appear as a word prefix ("trt ha" → "trt haber").
    /// Returns nil when the query has no searchable characters.
    public static func ftsPrefixQuery(_ query: String) -> String? {
        let words = tokens(inNormalized: normalize(query))
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }

    private static func tokens(inNormalized text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
