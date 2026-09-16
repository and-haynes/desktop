//  ReaderSpeechTests.swift
//  Sentence chunking for read aloud — and the offsets that make the highlight
//  land on the right words (#008BC).

import XCTest

@testable import Zen

final class ReaderSpeechTests: XCTestCase {

    private func texts(_ input: String) -> [String] {
        ReaderSpeechChunker.sentences(in: input).map(\.text)
    }

    // MARK: Splitting

    func testTerminatorsEndSentences() {
        XCTAssertEqual(
            texts("One thing. Another thing! A third? Yes."),
            ["One thing.", "Another thing!", "A third?", "Yes."])
    }

    func testARunOfTerminatorsIsOneBoundary() {
        XCTAssertEqual(texts("Really?! Yes... Indeed."), ["Really?!", "Yes...", "Indeed."])
    }

    /// A paragraph break is a sentence end even when the line has no full stop
    /// — headings and list items are most of an article's short lines.
    func testAParagraphBreakEndsASentence() {
        XCTAssertEqual(
            texts("A heading with no stop\nThe body follows."),
            ["A heading with no stop", "The body follows."])
    }

    func testAbbreviationsDoNotEndSentences() {
        XCTAssertEqual(texts("Dr. Ford arrived."), ["Dr. Ford arrived."])
        XCTAssertEqual(texts("Cats, dogs, etc. are fine."), ["Cats, dogs, etc. are fine."])
        XCTAssertEqual(texts("Ships vs. planes won."), ["Ships vs. planes won."])
    }

    func testInitialsDoNotEndSentences() {
        XCTAssertEqual(texts("J. R. R. Tolkien wrote it."), ["J. R. R. Tolkien wrote it."])
        XCTAssertEqual(texts("Use e.g. this one."), ["Use e.g. this one."])
    }

    /// `3.14` and `example.com` have no whitespace after the stop, which is the
    /// rule that catches both.
    func testDecimalsAndDomainsDoNotEndSentences() {
        XCTAssertEqual(texts("Pi is 3.14 and that is that."), ["Pi is 3.14 and that is that."])
        XCTAssertEqual(texts("Visit example.com today."), ["Visit example.com today."])
    }

    func testAClosingQuoteStaysWithItsSentence() {
        XCTAssertEqual(
            texts("He said \"go home.\" She left."), ["He said \"go home.\"", "She left."])
    }

    /// A page that never punctuates would otherwise hand the synthesizer the
    /// whole article and leave the highlight still for a minute.
    func testAVeryLongStretchIsBrokenUpAnyway() {
        let wall = String(repeating: "word ", count: 400)
        let sentences = ReaderSpeechChunker.sentences(in: wall)
        XCTAssertGreaterThan(sentences.count, 1)
        for sentence in sentences {
            XCTAssertLessThanOrEqual(
                sentence.text.count, ReaderSpeechChunker.maximumLength + 40,
                "a chunk is far past the cap, so the break did not take")
        }
    }

    func testWhitespaceOnlyAndPunctuationOnlyChunksAreDropped() {
        XCTAssertEqual(texts("   \n\n  \n"), [])
        XCTAssertEqual(texts("• \n— \nReal words here."), ["Real words here."])
        XCTAssertEqual(texts(""), [])
    }

    func testSentencesAreNumberedInOrder() {
        let sentences = ReaderSpeechChunker.sentences(in: "One. Two. Three.")
        XCTAssertEqual(sentences.map(\.index), [0, 1, 2])
    }

    // MARK: Offsets

    /// The whole point of the offsets: the reader page turns them into a DOM
    /// Range, so they have to name exactly the characters that were spoken.
    func testOffsetsSelectTheSentenceInTheSourceText() {
        let source = "First one. Second one! Third one?"
        let utf16 = Array(source.utf16)
        for sentence in ReaderSpeechChunker.sentences(in: source) {
            let slice = String(
                decoding: utf16[sentence.start..<sentence.end], as: UTF16.self)
            XCTAssertEqual(slice, sentence.text)
        }
    }

    /// UTF-16, not Characters: a JavaScript string index counts code units, so
    /// one emoji before the text would otherwise put every later highlight a
    /// character to the left — and keep doing it, silently.
    func testOffsetsAreUTF16SoAstralCharactersDoNotShiftTheHighlight() {
        let source = "🐝 buzz. Then quiet."
        let utf16 = Array(source.utf16)
        let sentences = ReaderSpeechChunker.sentences(in: source)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].start, 0)
        for sentence in sentences {
            let slice = String(
                decoding: utf16[sentence.start..<sentence.end], as: UTF16.self)
            XCTAssertEqual(slice, sentence.text)
        }
    }

    func testOffsetsNeverOverlapAndAlwaysAdvance() {
        let source = """
            A first paragraph, with a comma. And a second sentence.

            A second paragraph — this one has an em dash. And "a quote."
            """
        var previousEnd = -1
        for sentence in ReaderSpeechChunker.sentences(in: source) {
            XCTAssertGreaterThanOrEqual(sentence.start, previousEnd)
            XCTAssertGreaterThan(sentence.end, sentence.start)
            previousEnd = sentence.end
        }
    }

    func testLeadingAndTrailingWhitespaceIsOutsideTheOffsets() {
        let source = "   Padded sentence.   "
        let sentences = ReaderSpeechChunker.sentences(in: source)
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0].start, 3)
        XCTAssertEqual(sentences[0].text, "Padded sentence.")
    }

    // MARK: A real article's shape

    func testAnArticleShapedTextChunksSensibly() {
        let article = """
            The Bee Orchid

            By Dr. J. Smith

            The bee orchid, Ophrys apifera, is a species of orchid. It is \
            native to Europe. Its flowers resemble bees, i.e. they mimic the \
            insect to attract pollinators.

            Numbers matter here: 3.5 million plants were counted. Was that \
            enough? Nobody is sure.
            """
        let sentences = ReaderSpeechChunker.sentences(in: article)
        XCTAssertEqual(sentences.first?.text, "The Bee Orchid")
        XCTAssertTrue(sentences.contains { $0.text == "By Dr. J. Smith" })
        XCTAssertTrue(sentences.contains { $0.text.contains("3.5 million plants were counted.") })
        XCTAssertTrue(sentences.contains { $0.text == "Was that enough?" })
        XCTAssertEqual(sentences.last?.text, "Nobody is sure.")
    }
}
