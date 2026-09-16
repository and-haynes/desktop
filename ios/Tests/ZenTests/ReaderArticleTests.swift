//  ReaderArticleTests.swift
//  Parsing Readability's answer, and the reading time we put at the top of it
//  (#008BC).

import XCTest

@testable import Zen

final class ReaderArticleTests: XCTestCase {

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    // MARK: Parsing

    func testAFullArticleParses() {
        let raw = json([
            "title": "  The Death of the Newspaper  ",
            "byline": "By A. Reporter",
            "siteName": "The Paper",
            "excerpt": "A short summary.",
            "content": "<p>Once upon a time.</p>",
            "textContent": "Once upon a time.",
            "dir": "ltr",
            "lang": "en-GB",
        ])
        let url = URL(string: "https://example.com/story")!
        let article = ReaderArticle.parse(raw, url: url)
        XCTAssertEqual(article?.title, "The Death of the Newspaper")
        XCTAssertEqual(article?.byline, "By A. Reporter")
        XCTAssertEqual(article?.siteName, "The Paper")
        XCTAssertEqual(article?.contentHTML, "<p>Once upon a time.</p>")
        XCTAssertEqual(article?.language, "en-GB")
        XCTAssertEqual(article?.url, url)
    }

    /// Readability returns `null` for a page it decided is not an article, and
    /// the script reports a throw the same way. Both mean "no reader here",
    /// which is a different thing from "a reader showing nothing".
    func testAPageThatIsNotAnArticleParsesToNil() {
        XCTAssertNil(ReaderArticle.parse(json(["error": "not-an-article"]), url: nil))
        XCTAssertNil(ReaderArticle.parse(json(["error": "TypeError: oops"]), url: nil))
        XCTAssertNil(ReaderArticle.parse(json(["content": "   "]), url: nil))
        XCTAssertNil(ReaderArticle.parse(nil, url: nil))
        XCTAssertNil(ReaderArticle.parse("not json at all", url: nil))
    }

    /// Missing fields are ordinary — plenty of articles have no byline — and
    /// must not cost the extraction.
    func testMissingMetadataIsEmptyNotFatal() {
        let article = ReaderArticle.parse(
            json(["content": "<p>Body.</p>", "textContent": "Body."]), url: nil)
        XCTAssertNotNil(article)
        XCTAssertEqual(article?.byline, "")
        XCTAssertEqual(article?.siteName, "")
        XCTAssertEqual(article?.direction, "ltr")
    }

    /// `JSONSerialization` turns a JSON null into `NSNull`, not into nil, and
    /// "null" printed under a headline is how a feature looks unfinished.
    func testJSONNullsDoNotBecomeTheWordNull() {
        let raw = #"{"title": null, "byline": null, "content": "<p>Hi.</p>", "textContent": "Hi."}"#
        let article = ReaderArticle.parse(raw, url: nil)
        XCTAssertEqual(article?.title, "")
        XCTAssertEqual(article?.byline, "")
    }

    func testRightToLeftIsCarriedThroughAndAnythingElseIsNot() {
        let rtl = ReaderArticle.parse(
            json(["content": "<p>.</p>", "textContent": ".", "dir": "rtl"]), url: nil)
        XCTAssertEqual(rtl?.direction, "rtl")
        let nonsense = ReaderArticle.parse(
            json(["content": "<p>.</p>", "textContent": ".", "dir": "sideways"]), url: nil)
        XCTAssertEqual(nonsense?.direction, "ltr")
    }

    // MARK: Reading time

    func testWordCountIsWhitespaceSeparated() {
        XCTAssertEqual(ReaderArticle.wordCount(of: "one two three"), 3)
        XCTAssertEqual(ReaderArticle.wordCount(of: "  one \n two\tthree \n\n "), 3)
        XCTAssertEqual(ReaderArticle.wordCount(of: ""), 0)
        XCTAssertEqual(ReaderArticle.wordCount(of: "   "), 0)
    }

    func testReadingTimeIsTheWordCountOverTheReadingSpeed() {
        // 225 wpm: 900 words is exactly four minutes.
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 900), 4)
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 2250), 10)
        // Rounded to the nearest minute, not truncated.
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 800), 4)
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 700), 3)
    }

    /// "0 min read" is not something to tell anyone, and an empty article is
    /// still an article you spent a second on.
    func testAVeryShortArticleIsStillOneMinute() {
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 1), 1)
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 0), 1)
        XCTAssertEqual(ReaderArticle.readingMinutes(words: 100), 1)
    }

    /// The brief said 200–250 wpm; the constant has to stay inside that or the
    /// label starts lying by a third.
    func testTheReadingSpeedIsInTheRangeItClaims() {
        XCTAssertTrue((200.0...250.0).contains(ReaderArticle.wordsPerMinute))
    }

    func testTheLabelReadsAsASentence() {
        let article = ReaderArticle.parse(
            json([
                "content": "<p>x</p>",
                "textContent": String(repeating: "word ", count: 450),
            ]), url: nil)
        XCTAssertEqual(article?.wordCount, 450)
        XCTAssertEqual(article?.readingTimeLabel, "2 min read")
    }
}
