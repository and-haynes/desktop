//  ReaderTemplateTests.swift
//  The bridge from a settings value to the CSS the reader page runs on
//  (#008BC).
//
//  The initial document and the live restyle are generated from one function,
//  so what is asserted here is that function — plus the two escapes, which are
//  the only places a web page's own text reaches our markup and our JavaScript.

import XCTest

@testable import Zen

final class ReaderTemplateTests: XCTestCase {

    private func variables(_ settings: ReaderSettings) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: ReaderTemplate.cssVariables(
                for: settings, insets: ReaderInsets()
            ).map { ($0.name, $0.value) })
    }

    // MARK: Variables

    func testEverySettingReachesACustomProperty() {
        var settings = ReaderSettings()
        settings.font = .georgia
        settings.fontSize = 22
        settings.lineHeight = 1.8
        settings.letterSpacing = 0.05
        settings.contentWidth = 480
        settings.paragraphSpacing = 1.4
        settings.alignment = .justified
        settings.theme = .sepia

        let vars = variables(settings)
        XCTAssertEqual(vars["--zen-reader-size"], "22px")
        XCTAssertEqual(vars["--zen-reader-leading"], "1.8")
        XCTAssertEqual(vars["--zen-reader-tracking"], "0.05em")
        XCTAssertEqual(vars["--zen-reader-measure"], "480px")
        XCTAssertEqual(vars["--zen-reader-para-space"], "1.4em")
        XCTAssertEqual(vars["--zen-reader-align"], "justify")
        XCTAssertEqual(vars["--zen-reader-font"], ReaderFont.georgia.cssStack)
        XCTAssertEqual(vars["--zen-reader-bg"], settings.palette.background.hexString)
        XCTAssertEqual(vars["--zen-reader-fg"], settings.palette.text.hexString)
        XCTAssertEqual(vars["--zen-reader-link"], settings.palette.link.hexString)
    }

    /// Out-of-range values are clamped on the way to CSS as well as on the way
    /// into the file — the panel is not the only thing that can set them.
    func testTheStylesheetNeverSeesAnUnclampedValue() {
        var settings = ReaderSettings()
        settings.fontSize = 10_000
        XCTAssertEqual(
            variables(settings)["--zen-reader-size"],
            "\(Int(ReaderSettings.fontSizeRange.upperBound))px")
    }

    /// Hyphenating a left-aligned column gives you a ragged edge *and* broken
    /// words, which is the worst of both. The toggle only applies to justified.
    func testHyphenationOnlyAppliesToJustifiedText() {
        var settings = ReaderSettings()
        settings.hyphenation = true
        settings.alignment = .left
        XCTAssertEqual(variables(settings)["--zen-reader-hyphens"], "manual")

        settings.alignment = .justified
        XCTAssertEqual(variables(settings)["--zen-reader-hyphens"], "auto")

        settings.hyphenation = false
        XCTAssertEqual(variables(settings)["--zen-reader-hyphens"], "manual")
    }

    func testModesAreClassesRatherThanValues() {
        var settings = ReaderSettings()
        XCTAssertEqual(ReaderTemplate.bodyClasses(for: settings), [])
        settings.showImages = false
        settings.dropCaps = true
        XCTAssertEqual(
            Set(ReaderTemplate.bodyClasses(for: settings)), ["zen-no-images", "zen-drop-caps"])
    }

    /// Whole numbers read as decisions; `19.0px` reads as a leaked float.
    func testNumbersAreFormattedWithoutStrayPrecision() {
        XCTAssertEqual(ReaderTemplate.trim(19), "19")
        XCTAssertEqual(ReaderTemplate.trim(1.6), "1.6")
        XCTAssertEqual(ReaderTemplate.trim(-0.03), "-0.03")
        // `%g` would make this `1e-07`, which CSS cannot parse as a length —
        // the property would be dropped and the control would look broken.
        XCTAssertFalse(ReaderTemplate.trim(0.0000001).contains("e"))
        XCTAssertFalse(ReaderTemplate.trim(-0.0000001).contains("e"))
    }

    // MARK: The restyle script

    func testTheApplyScriptSetsTheSamePropertiesTheDocumentDeclares() {
        var settings = ReaderSettings()
        settings.theme = .dark
        settings.font = .systemMono
        let script = ReaderTemplate.applyScript(for: settings, insets: ReaderInsets())
        for (name, _) in ReaderTemplate.cssVariables(for: settings, insets: ReaderInsets()) {
            XCTAssertTrue(
                script.contains("'\(name)'"),
                "\(name) is declared in the document but never updated live")
        }
        // Both classes are always named, so turning one *off* is as much an
        // update as turning it on.
        XCTAssertTrue(script.contains("zen-no-images"))
        XCTAssertTrue(script.contains("zen-drop-caps"))
    }

    /// Font stacks contain apostrophes ('SF Mono'), which is exactly the value
    /// that breaks naive interpolation into a single-quoted JS literal.
    func testAFontStackWithQuotesSurvivesTheJourneyIntoJavaScript() {
        var settings = ReaderSettings()
        settings.font = .systemMono
        let script = ReaderTemplate.applyScript(for: settings, insets: ReaderInsets())
        XCTAssertTrue(script.contains("\\'SF Mono\\'"))
        XCTAssertFalse(script.contains("'SF Mono'"))
    }

    func testJSStringEscapesTheThingsThatEndAStringLiteral() {
        XCTAssertEqual(ReaderTemplate.jsString("plain"), "'plain'")
        XCTAssertEqual(ReaderTemplate.jsString("it's"), "'it\\'s'")
        XCTAssertEqual(ReaderTemplate.jsString("back\\slash"), "'back\\\\slash'")
        XCTAssertEqual(ReaderTemplate.jsString("two\nlines"), "'two\\nlines'")
    }

    // MARK: The document

    func testTheDocumentCarriesTheArticleAndItsReadingTime() {
        let article = ReaderArticle(
            title: "A Title", byline: "By Someone", siteName: "A Site", excerpt: "",
            contentHTML: "<p>Hello world.</p>",
            textContent: String(repeating: "word ", count: 450),
            direction: "ltr", language: "en", url: URL(string: "https://example.com/a"))
        let html = ReaderTemplate.document(
            article: article, settings: ReaderSettings(), insets: ReaderInsets())
        XCTAssertTrue(html.contains("A Title"))
        XCTAssertTrue(html.contains("By Someone"))
        XCTAssertTrue(html.contains("A Site"))
        XCTAssertTrue(html.contains("<p>Hello world.</p>"))
        XCTAssertTrue(html.contains("2 min read"))
        XCTAssertTrue(html.contains("450 words"))
        XCTAssertTrue(html.contains("lang=\"en\""))
    }

    /// A headline is a web page's text going into our markup. `Bob's <b>Blog</b>`
    /// in a title must render as those characters, not as markup of its own.
    func testTitlesAndBylinesAreEscaped() {
        let article = ReaderArticle(
            title: "Bob's <b>Blog</b> & Co", byline: "<script>alert(1)</script>",
            siteName: "", excerpt: "", contentHTML: "<p>x</p>", textContent: "x",
            direction: "ltr", language: "", url: nil)
        let html = ReaderTemplate.document(
            article: article, settings: ReaderSettings(), insets: ReaderInsets())
        XCTAssertTrue(html.contains("Bob&#39;s &lt;b&gt;Blog&lt;/b&gt; &amp; Co"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }

    func testAMissingBylineLeavesNoEmptyLine() {
        let article = ReaderArticle(
            title: "T", byline: "", siteName: "", excerpt: "", contentHTML: "<p>x</p>",
            textContent: "x", direction: "ltr", language: "", url: nil)
        let html = ReaderTemplate.document(
            article: article, settings: ReaderSettings(), insets: ReaderInsets())
        // The class names are always in the stylesheet; what must be absent is
        // the *markup*, so that a byline-less article has no empty line under
        // its headline.
        XCTAssertFalse(html.contains("<p class=\"zen-reader-byline\">"))
        XCTAssertFalse(html.contains("<p class=\"zen-reader-site\">"))
    }

    func testTheDocumentDeclaresTheCustomPropertiesItsStylesheetReads() {
        let article = ReaderArticle(
            title: "T", byline: "", siteName: "", excerpt: "", contentHTML: "<p>x</p>",
            textContent: "x", direction: "ltr", language: "", url: nil)
        let html = ReaderTemplate.document(
            article: article, settings: ReaderSettings(), insets: ReaderInsets())
        for (name, _) in ReaderTemplate.cssVariables(for: ReaderSettings(), insets: ReaderInsets())
        {
            XCTAssertTrue(html.contains("\(name):"), "\(name) is read but never declared")
        }
    }
}
