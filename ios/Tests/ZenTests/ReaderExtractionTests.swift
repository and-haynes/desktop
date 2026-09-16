//  ReaderExtractionTests.swift
//  That Mozilla's library is really in the bundle, and that the scripts we
//  wrap it in are the shape they claim to be (#008BC).
//
//  Whether Readability finds the right article is Mozilla's problem and is
//  covered by Mozilla's own test corpus; re-verifying it here would be copying
//  someone else's suite. What is ours is the plumbing: the resource ships, the
//  heavy library is only reached for on demand, and the injection is an
//  evaluate rather than a user script.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class ReaderExtractionTests: XCTestCase {

    func testBothLibrariesAreInTheAppBundle() {
        XCTAssertNotNil(ReaderExtraction.library, "Readability.js is not bundled")
        XCTAssertNotNil(
            ReaderExtraction.readerableLibrary, "Readability-readerable.js is not bundled")
    }

    /// A truncated or replaced resource would still be a non-nil string, so
    /// check for the two entry points the scripts actually call.
    func testTheBundledLibrariesAreTheOnesWeThinkTheyAre() throws {
        let library = try XCTUnwrap(ReaderExtraction.library)
        XCTAssertTrue(library.contains("function Readability("))
        XCTAssertTrue(library.contains("Readability.prototype = {"))
        XCTAssertTrue(library.contains("parse() {"))
        XCTAssertTrue(
            library.contains("raw.githubusercontent.com/mozilla/readability"),
            "the provenance header is gone — a vendored file has to say where it came from")

        let readerable = try XCTUnwrap(ReaderExtraction.readerableLibrary)
        XCTAssertTrue(readerable.contains("function isProbablyReaderable("))
    }

    /// The cheap probe runs on every page that loads; the 90 KB parser must
    /// not be anywhere near it.
    func testTheProbeCarriesOnlyTheSmallLibrary() throws {
        let readerable = try XCTUnwrap(ReaderExtraction.readerableLibrary)
        let script = ReaderExtraction.readerableScript(library: readerable)
        XCTAssertTrue(script.contains("isProbablyReaderable"))
        XCTAssertFalse(
            script.contains("function Readability("),
            "the probe is dragging the parser along with it")
    }

    /// Readability rewrites the document it is given. Handing it the live one
    /// would gut the page behind the reader, leaving nothing to go back to.
    func testTheParseRunsOnACloneOfTheDocument() throws {
        let library = try XCTUnwrap(ReaderExtraction.library)
        let script = ReaderExtraction.parseScript(library: library)
        XCTAssertTrue(script.contains("document.cloneNode(true)"))
    }

    /// Both scripts cache their library on `window`, so invoking the reader
    /// twice on one page is a function call rather than 90 KB of parsing.
    func testTheLibrariesAreEvaluatedAtMostOncePerDocument() throws {
        let library = try XCTUnwrap(ReaderExtraction.library)
        let readerable = try XCTUnwrap(ReaderExtraction.readerableLibrary)
        XCTAssertTrue(ReaderExtraction.parseScript(library: library).contains("window.__zenReadability"))
        XCTAssertTrue(
            ReaderExtraction.readerableScript(library: readerable)
                .contains("window.__zenIsReaderable"))
    }

    /// Both scripts answer in-band rather than throwing across the bridge: a
    /// page that refuses scripts, or a parse that throws, has to read as "no
    /// article here" and not as a broken button.
    func testBothScriptsSwallowTheirOwnFailures() throws {
        let library = try XCTUnwrap(ReaderExtraction.library)
        let readerable = try XCTUnwrap(ReaderExtraction.readerableLibrary)
        XCTAssertTrue(ReaderExtraction.parseScript(library: library).contains("catch (e)"))
        XCTAssertTrue(ReaderExtraction.readerableScript(library: readerable).contains("catch (e)"))
    }

    /// The load-bearing one (#008AB). Reader extraction reads `document` and
    /// nothing else, but it still must never be *installed*: a user script runs
    /// in every page, including the one a password is typed into, and one that
    /// touches login markup takes iOS Password AutoFill away with no error to
    /// explain it. `AutoFillSuppressionTests` scans the browsing configuration
    /// for exactly that; this asserts the reader did not add anything for it to
    /// find.
    func testReaderModeAddsNoUserScriptToTheBrowsingConfiguration() {
        let space = Space(name: "Reader", icon: "book", isSymbol: true)
        let before = WebEngine.configuration(for: space, desktop: false)
            .userContentController.userScripts.count
        // The media observer, and nothing else.
        XCTAssertEqual(before, 1)
        for script in WebEngine.configuration(for: space, desktop: false)
            .userContentController.userScripts
        {
            XCTAssertFalse(
                script.source.contains("Readability"),
                "Readability is being injected as a user script — it must be evaluated on demand")
        }
    }
}
