//  ReaderExtraction.swift
//  Getting the article out of the page, with Mozilla's own library (#008BC).
//
//  WebKit exposes no reader API to a third-party app — Safari's Reader is
//  Safari's, and nothing in WKWebView reaches it. So Zen does what Firefox and
//  Zen desktop do and runs **Readability.js** over the live document. The
//  library is vendored verbatim in `Readability.js`; this file is only the two
//  questions we ask it.
//
//  ## Two libraries, two costs
//
//  `Readability-readerable.js` is ~4 KB and answers "does this look like an
//  article?" without parsing anything. That is cheap enough to ask on every
//  page that finishes loading, which is what lets the reader button appear by
//  itself instead of being a menu item that usually disappoints.
//
//  `Readability.js` is ~90 KB and rewrites a clone of the document. That is
//  *not* something to do on every page load, so it is evaluated only when
//  reader mode is actually invoked, and cached on `window` so a second
//  invocation on the same document costs one function call.
//
//  ## Why this is an `evaluateJavaScript`, never a user script
//
//  A `WKUserScript` runs in every page, including the one you type a password
//  into, and `AutoFillSuppressionTests` fails the build for any injected script
//  that so much as mentions an input — for good reason (#008AB): a script that
//  touches login markup stops iOS recognising it and Password AutoFill goes
//  quiet with no error to explain it. Reader extraction only ever *reads*
//  `document`, but it is still evaluated on demand into the isolated
//  `.defaultClient` content world rather than installed, so a page you are not
//  reading never sees it at all.

import Foundation
import WebKit

enum ReaderExtraction {

    /// Where the vendored libraries live in the app bundle.
    private static let libraryResource = "Readability"
    private static let readerableResource = "Readability-readerable"

    /// Loaded once. A missing resource is a build error in practice, so it is
    /// asserted in debug and degrades to "no reader anywhere" in release —
    /// never to a crash in someone's browser.
    static let library: String? = load(libraryResource)
    static let readerableLibrary: String? = load(readerableResource)

    private static func load(_ name: String) -> String? {
        guard let url = Bundle.reader.url(forResource: name, withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("Zen: \(name).js is missing from the bundle")
            return nil
        }
        return source
    }

    // MARK: The two scripts

    /// "Is there an article here?" — the cheap probe.
    ///
    /// Wrapped in a function so the library's top-level declarations stay out
    /// of the world's globals except for the one handle we keep, and so the
    /// second call on a document is just that handle.
    static func readerableScript(library: String) -> String {
        """
        (function () {
          try {
            if (!window.__zenIsReaderable) {
              (function () {
                \(library)
                window.__zenIsReaderable = isProbablyReaderable;
              })();
            }
            return window.__zenIsReaderable(document) === true;
          } catch (e) {
            return false;
          }
        })()
        """
    }

    /// "Give me the article" — the parse, as a JSON string.
    ///
    /// `document.cloneNode(true)` because Readability rewrites the document it
    /// is handed; running it on the live one would gut the page behind the
    /// reader and leave nothing to go back to.
    static func parseScript(library: String) -> String {
        """
        (function () {
          try {
            if (!window.__zenReadability) {
              (function () {
                \(library)
                window.__zenReadability = Readability;
              })();
            }
            var clone = document.cloneNode(true);
            var article = new window.__zenReadability(clone).parse();
            if (!article) { return JSON.stringify({ error: "not-an-article" }); }
            return JSON.stringify({
              title: article.title || "",
              byline: article.byline || "",
              siteName: article.siteName || "",
              excerpt: article.excerpt || "",
              content: article.content || "",
              textContent: article.textContent || "",
              dir: article.dir || "",
              lang: article.lang || ""
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        })()
        """
    }
}

/// `Bundle.main` is the app in a hosted unit test too (ZenTests runs with
/// `TEST_HOST`), but naming the bundle through a type in this module keeps
/// that true if the test target ever loses its host.
extension Bundle {
    fileprivate static var reader: Bundle {
        final class Token {}
        return Bundle(for: Token.self)
    }
}

// MARK: - Asking a page

extension ZenWebView {

    /// Does this page look like an article? Answers `false` for anything that
    /// cannot be asked — a PDF, an error page, a document that refuses scripts.
    func checkReaderable(_ completion: @escaping (Bool) -> Void) {
        guard let library = ReaderExtraction.readerableLibrary else {
            completion(false)
            return
        }
        evaluateJavaScript(
            ReaderExtraction.readerableScript(library: library), in: nil,
            in: .defaultClient
        ) { result in
            switch result {
            case .success(let value): completion((value as? Bool) == true)
            case .failure: completion(false)
            }
        }
    }

    /// Extract the article, or nil where there is none.
    func extractArticle(_ completion: @escaping (ReaderArticle?) -> Void) {
        guard let library = ReaderExtraction.library else {
            completion(nil)
            return
        }
        let pageURL = url
        evaluateJavaScript(
            ReaderExtraction.parseScript(library: library), in: nil, in: .defaultClient
        ) { result in
            switch result {
            case .success(let value): completion(ReaderArticle.parse(value, url: pageURL))
            case .failure: completion(nil)
            }
        }
    }
}
