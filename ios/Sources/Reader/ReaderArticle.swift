//  ReaderArticle.swift
//  What Readability handed back, and the two numbers we derive from it.
//
//  `Readability.parse()` returns a plain object; this is the Swift value it
//  becomes. Parsing is deliberately total — every field falls back to empty
//  rather than failing the whole extraction, because a page with no byline is
//  still perfectly readable and a reader that refuses to open one is not.

import Foundation

struct ReaderArticle: Equatable, Sendable {
    /// Readability's own title, which is the `<h1>`/`og:title` it trusted —
    /// often cleaner than `document.title`, which carries the site name.
    var title: String
    var byline: String
    var siteName: String
    var excerpt: String
    /// Sanitised article HTML. Readability strips scripts; it is rendered into
    /// the reader template as-is.
    var contentHTML: String
    /// The same content as plain text. What read-aloud speaks and what the
    /// word count is taken from.
    var textContent: String
    /// `dir="rtl"` where the page said so.
    var direction: String
    var language: String
    var url: URL?

    /// Words, by whitespace. Not a linguistics exercise: the number exists to
    /// divide by a reading speed, and any two definitions of "word" agree to
    /// within a rounding error at that resolution.
    var wordCount: Int { Self.wordCount(of: textContent) }

    /// Minutes, rounded to the nearest whole one and never zero — "0 min read"
    /// is not a thing to tell someone.
    var readingMinutes: Int {
        Self.readingMinutes(words: wordCount)
    }

    /// "4 min read" / "1 min read".
    var readingTimeLabel: String { "\(readingMinutes) min read" }

    /// Adult silent reading of non-technical prose sits around 220–260 wpm;
    /// the brief said 200–250, so this is the middle of the overlap. One
    /// constant so the tests and the label can never disagree.
    static let wordsPerMinute: Double = 225

    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func readingMinutes(
        words: Int, wordsPerMinute rate: Double = ReaderArticle.wordsPerMinute
    ) -> Int {
        guard words > 0, rate > 0 else { return 1 }
        return max(1, Int((Double(words) / rate).rounded()))
    }

    // MARK: Parsing

    /// Turn the JSON string the extraction script returns into an article.
    ///
    /// Returns nil for the two honest failures — Readability decided there was
    /// no article here (`null`), or the script threw — so the caller can say
    /// "this page has no article" rather than opening an empty reader.
    static func parse(_ raw: Any?, url: URL?) -> ReaderArticle? {
        guard let string = raw as? String, let data = string.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(json: json, url: url)
    }

    static func parse(json: [String: Any], url: URL?) -> ReaderArticle? {
        // The script reports its own failures in-band; a page that is simply
        // not an article and a page whose parse threw are both "no reader".
        guard json["error"] == nil else { return nil }
        let content = (json["content"] as? String) ?? ""
        let text = (json["textContent"] as? String) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReaderArticle(
            title: clean(json["title"]),
            byline: clean(json["byline"]),
            siteName: clean(json["siteName"]),
            excerpt: clean(json["excerpt"]),
            contentHTML: content,
            textContent: text,
            direction: (json["dir"] as? String).flatMap { $0 == "rtl" ? "rtl" : "ltr" } ?? "ltr",
            language: (json["lang"] as? String) ?? "",
            url: url)
    }

    /// `null` decodes to `NSNull`, not to nil, and a byline of "null" printed
    /// under a headline is the kind of detail that makes a feature feel unfinished.
    private static func clean(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
