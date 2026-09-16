//  ReaderExtractionLiveTests.swift
//  The extraction path end to end, against a real DOM (#008BC).
//
//  Readability is JavaScript that reads a document, so the only honest way to
//  exercise our half of it is to give it one — `JSContext` has no `document`.
//  These load fixture HTML into an off-screen `ZenWebView` and call the
//  *shipped* `checkReaderable` / `extractArticle`, so what is under test is the
//  whole path: the bundled resource, the wrapper that caches it on `window`,
//  the isolated content world, and the JSON coming back across the bridge.
//
//  What is deliberately *not* under test is whether Readability picks the right
//  paragraphs. That is Mozilla's library and Mozilla's corpus; re-asserting it
//  here would be maintaining a copy of someone else's suite. The two fixtures
//  are an article-shaped page and a page that is plainly not one, which is
//  enough to prove the answer depends on the document at all.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class ReaderExtractionLiveTests: XCTestCase {

    private static let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
    }

    /// Held for the duration of the test: a web view's delegate is weak, and a
    /// deallocated one simply never calls back, which reads as a hang.
    private var waiters: [LoadWaiter] = []

    private func load(_ html: String) async -> ZenWebView {
        let space = Space(name: "Reader", icon: "book", isSymbol: true)
        let webView = ZenWebView(
            frame: Self.viewport,
            configuration: WebEngine.configuration(for: space, desktop: false))
        let waiter = LoadWaiter()
        waiters.append(waiter)
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.onFinish = { continuation.resume() }
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/article"))
        }
        return webView
    }

    private func readerable(_ html: String) async -> Bool {
        let webView = await load(html)
        return await withCheckedContinuation { continuation in
            webView.checkReaderable { continuation.resume(returning: $0) }
        }
    }

    private func extract(_ html: String) async -> ReaderArticle? {
        let webView = await load(html)
        return await withCheckedContinuation { continuation in
            webView.extractArticle { continuation.resume(returning: $0) }
        }
    }

    // MARK: Fixtures

    /// Article-shaped: a headline, a byline, several substantial paragraphs,
    /// and the furniture a real page carries around them.
    private static let article = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>The Bee Orchid — Fixture Botanical Review</title>
          <meta property="og:site_name" content="Fixture Botanical Review">
        </head>
        <body>
          <nav id="site-nav"><a href="/">Home</a> <a href="/about">About</a></nav>
          <article>
            <h1>The Bee Orchid</h1>
            <p class="byline">By Dr. Jane Fixture</p>
            <p>The bee orchid, Ophrys apifera, is a species of orchid native to much of
            Europe, North Africa and the Middle East. Its flowers are among the most
            remarkable in the European flora, because each one is a passable imitation of
            a female bee, complete with a furred, rounded lip and a pattern of markings
            that reads convincingly from a short distance away.</p>
            <p>The mimicry is not only visual. The flower releases a scent close enough to
            the pheromone of the female insect that males approach it, attempt to mate
            with the lip, and leave carrying pollen on their heads. This arrangement is
            known as pseudocopulation, and it is the mechanism on which a great many
            Ophrys species depend for their pollination across the whole of their range.</p>
            <p>In Britain the species has largely given up on the bees. The insect whose
            females the flower imitates does not occur here, so British populations are
            almost entirely self-pollinating, and the elaborate deception is performed to
            an audience that never arrives. Botanists have described this as a relict
            behaviour, retained because nothing has yet selected against it strongly.</p>
            <p>Populations fluctuate wildly from year to year. A meadow may carry hundreds
            of spikes one summer and none the next, which makes the plant unusually
            difficult to monitor and unusually satisfying to find. The seeds are dust-like
            and depend on a fungal partner in the soil before a seedling can establish.</p>
          </article>
          <aside id="related"><a href="/x">More stories</a></aside>
          <footer>Copyright 2026 Fixture Botanical Review</footer>
        </body>
        </html>
        """

    /// Not an article: a dashboard of links and labels, which is what most of
    /// the web that is not an article actually looks like.
    private static let notAnArticle = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Fixture Dashboard</title></head>
        <body>
          <header><h1>Dashboard</h1></header>
          <nav><a href="/a">Alpha</a><a href="/b">Beta</a><a href="/c">Gamma</a></nav>
          <ul>
            <li><a href="/1">Service one</a> — up</li>
            <li><a href="/2">Service two</a> — up</li>
            <li><a href="/3">Service three</a> — degraded</li>
          </ul>
          <table><tr><td>CPU</td><td>14%</td></tr><tr><td>RAM</td><td>3.1 GB</td></tr></table>
        </body>
        </html>
        """

    // MARK: The probe

    func testTheProbeSaysYesToAnArticle() async {
        let answer = await readerable(Self.article)
        XCTAssertTrue(answer, "the probe did not recognise an article-shaped page")
    }

    func testTheProbeSaysNoToAPageOfLinks() async {
        let answer = await readerable(Self.notAnArticle)
        XCTAssertFalse(answer, "the probe offered the reader on a dashboard")
    }

    // MARK: The parse

    func testAnArticleExtractsItsTitleBylineAndBody() async throws {
        let extracted = await extract(Self.article)
        let article = try XCTUnwrap(extracted)
        // `contains`, not `==`: Readability takes the title from `<title>` when
        // it cannot confidently strip the site name off it, so the headline
        // arrives with or without " — Fixture Botanical Review" depending on
        // the separator. Which of those it picks is Mozilla's call, not ours.
        XCTAssertTrue(article.title.contains("The Bee Orchid"), article.title)
        XCTAssertTrue(article.byline.contains("Jane Fixture"))
        XCTAssertTrue(article.contentHTML.contains("pseudocopulation"))
        XCTAssertTrue(article.textContent.contains("Ophrys apifera"))
        XCTAssertEqual(article.url?.absoluteString, "https://fixture.test/article")
    }

    /// The furniture is the whole point of a reader: navigation, the related
    /// rail and the copyright line have to be gone.
    func testTheChromeAroundTheArticleIsStripped() async {
        let article = await extract(Self.article)
        XCTAssertNotNil(article)
        XCTAssertFalse(article?.contentHTML.contains("site-nav") == true)
        XCTAssertFalse(article?.contentHTML.contains("More stories") == true)
        XCTAssertFalse(article?.textContent.contains("Copyright 2026") == true)
    }

    /// Readability rewrites the document it is given, so the parse runs on a
    /// clone. If it did not, the page behind the reader would be gutted and
    /// closing the reader would show wreckage.
    func testExtractionLeavesTheLivePageUntouched() async {
        let webView = await load(Self.article)
        _ = await withCheckedContinuation { continuation in
            webView.extractArticle { continuation.resume(returning: $0) }
        }
        let navigation = try? await webView.evaluateJavaScript(
            "document.getElementById('site-nav') !== null")
        XCTAssertEqual(
            navigation as? Bool, true,
            "the live document lost its navigation — the parse ran on the page, not a clone")
    }

    /// The reading time at the top of the reader comes off this word count, so
    /// it has to be the article's words and not the whole page's.
    func testTheWordCountIsTheArticlesNotThePages() async {
        let article = await extract(Self.article)
        let words = article?.wordCount ?? 0
        XCTAssertGreaterThan(words, 200)
        XCTAssertLessThan(words, 400)
        XCTAssertEqual(article?.readingMinutes, 1)
    }

    /// Readability will hand *something* back for almost any page — it is a
    /// salvage algorithm, not a classifier. That is precisely why the affordance
    /// is gated on the probe (above) and not on the parse: what separates an
    /// article from a dashboard here is how much prose comes out, and the
    /// difference is an order of magnitude.
    func testADashboardYieldsAFractionOfWhatAnArticleDoes() async throws {
        let extracted = await extract(Self.article)
        let article = try XCTUnwrap(extracted)
        let dashboard = await extract(Self.notAnArticle)
        XCTAssertLessThan(
            dashboard?.wordCount ?? 0, article.wordCount / 4,
            "a page of links extracted as much prose as an article did")
    }
}
