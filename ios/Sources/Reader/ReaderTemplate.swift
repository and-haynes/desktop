//  ReaderTemplate.swift
//  The page the reader actually renders, and the one channel that restyles it.
//
//  Readability hands back sanitised article HTML; this wraps it in a document
//  of Zen's own. Every appearance control is a **CSS custom property** or a
//  class on `<html>`, and `applyScript` sets exactly those — so changing a
//  slider is one `evaluateJavaScript` that costs a repaint, never a reload.
//  That matters more than it sounds: a reload loses your place in the article,
//  and an appearance control that scrolls you back to the top is one you use
//  once.
//
//  The initial document and the live update are generated from the *same*
//  `cssVariables(for:)`, so the two cannot drift — a setting added to one is
//  added to both or to neither.
//
//  ## The highlight is drawn, not inserted
//
//  Marking the sentence being read aloud by wrapping it in a `<mark>` needs
//  `Range.surroundContents`, which throws the moment a sentence crosses an
//  inline element — and a sentence with a link or an <em> in it is most of
//  them. Rewriting the DOM would also invalidate the text index the offsets are
//  measured against. So the highlight is a set of absolutely positioned
//  rectangles taken from `Range.getClientRects()`, painted *behind* the text in
//  an overlay layer. Nothing in the article moves, and a range that spans six
//  elements and three lines highlights correctly.

import Foundation

/// Space the SwiftUI chrome needs at each end of the page, in points.
struct ReaderInsets: Equatable, Sendable {
    var top: Double = 96
    var bottom: Double = 120
}

enum ReaderTemplate {

    /// The name the page posts progress and readiness on.
    static let messageHandlerName = "zenReader"

    // MARK: Variables

    /// Every custom property the stylesheet reads, in one place.
    ///
    /// Pure and ordered, so it can be asserted directly: this is the function
    /// `ReaderTemplateTests` drives rather than scraping the rendered CSS.
    static func cssVariables(for settings: ReaderSettings, insets: ReaderInsets)
        -> [(name: String, value: String)]
    {
        let s = settings.clamped()
        let palette = s.palette
        return [
            ("--zen-reader-bg", palette.background.hexString),
            ("--zen-reader-fg", palette.text.hexString),
            ("--zen-reader-secondary", palette.secondary.hexString),
            ("--zen-reader-link", palette.link.hexString),
            ("--zen-reader-border", palette.border.hexString),
            ("--zen-reader-highlight", palette.highlight.hexString),
            ("--zen-reader-font", s.font.cssStack),
            ("--zen-reader-size", "\(trim(s.fontSize))px"),
            ("--zen-reader-leading", trim(s.lineHeight)),
            ("--zen-reader-tracking", "\(trim(s.letterSpacing))em"),
            ("--zen-reader-measure", "\(trim(s.contentWidth))px"),
            ("--zen-reader-para-space", "\(trim(s.paragraphSpacing))em"),
            ("--zen-reader-align", s.alignment.cssValue),
            // Hyphenation is only ever asked for under justification; left-
            // aligned hyphenated text is a ragged edge *and* broken words.
            (
                "--zen-reader-hyphens",
                s.alignment == .justified && s.hyphenation ? "auto" : "manual"
            ),
            ("--zen-reader-pad-top", "\(trim(insets.top))px"),
            ("--zen-reader-pad-bottom", "\(trim(insets.bottom))px"),
        ]
    }

    /// Classes on `<html>` for the things that are a mode rather than a value.
    static func bodyClasses(for settings: ReaderSettings) -> [String] {
        var classes: [String] = []
        if !settings.showImages { classes.append("zen-no-images") }
        if settings.dropCaps { classes.append("zen-drop-caps") }
        return classes
    }

    /// Restyle a live reader document. Idempotent, and safe to call on a page
    /// that has not finished loading — the properties simply land early.
    static func applyScript(for settings: ReaderSettings, insets: ReaderInsets) -> String {
        let assignments = cssVariables(for: settings, insets: insets)
            .map { "  r.style.setProperty('\($0.name)', \(jsString($0.value)));" }
            .joined(separator: "\n")
        let classes = bodyClasses(for: settings).map(jsString).joined(separator: ", ")
        return """
            (function () {
              var r = document.documentElement;
            \(assignments)
              var wanted = [\(classes)];
              ['zen-no-images', 'zen-drop-caps'].forEach(function (name) {
                r.classList.toggle(name, wanted.indexOf(name) !== -1);
              });
              // The highlight is measured in layout coordinates, so anything
              // that reflows the article has to redraw it.
              if (window.zenReaderRedrawHighlight) { window.zenReaderRedrawHighlight(); }
              return true;
            })()
            """
    }

    // MARK: The document

    static func document(
        article: ReaderArticle, settings: ReaderSettings, insets: ReaderInsets
    ) -> String {
        let variables = cssVariables(for: settings, insets: insets)
            .map { "  \($0.name): \($0.value);" }
            .joined(separator: "\n")
        let classes = bodyClasses(for: settings).joined(separator: " ")
        let language = article.language.isEmpty ? "en" : article.language

        let siteLine = article.siteName.isEmpty ? "" :
            "<p class=\"zen-reader-site\">\(escape(article.siteName))</p>"
        let bylineLine = article.byline.isEmpty ? "" :
            "<p class=\"zen-reader-byline\">\(escape(article.byline))</p>"
        let meta =
            "\(article.readingTimeLabel) · \(article.wordCount) words"

        return """
            <!DOCTYPE html>
            <html lang="\(escape(language))" dir="\(article.direction)" class="\(classes)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, \
            maximum-scale=1, viewport-fit=cover">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
            img-src * data: blob:; media-src * data: blob:; style-src 'unsafe-inline'; \
            font-src *; script-src 'unsafe-inline'; connect-src 'none'">
            <style>
            :root {
            \(variables)
            }
            \(stylesheet)
            </style>
            </head>
            <body>
            <div id="zen-reader-highlights" aria-hidden="true"></div>
            <div id="zen-reader-root">
              <header id="zen-reader-header">
                \(siteLine)
                <h1 class="zen-reader-title">\(escape(article.title))</h1>
                \(bylineLine)
                <p class="zen-reader-meta">\(escape(meta))</p>
              </header>
              <article id="zen-reader-content">
            \(article.contentHTML)
              </article>
              <footer id="zen-reader-footer">Extracted with Mozilla Readability</footer>
            </div>
            <script>
            \(pageScript)
            </script>
            </body>
            </html>
            """
    }

    // MARK: Style

    /// Quoted from nothing — Zen desktop's reader is Firefox's, whose
    /// stylesheet is Gecko-specific. The measurements are chosen for a phone
    /// held at reading distance and are all overridable by the panel anyway.
    private static let stylesheet = """
        * { -webkit-text-size-adjust: none; }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--zen-reader-bg);
          color: var(--zen-reader-fg);
        }
        body {
          font-family: var(--zen-reader-font);
          font-size: var(--zen-reader-size);
          line-height: var(--zen-reader-leading);
          letter-spacing: var(--zen-reader-tracking);
          -webkit-font-smoothing: antialiased;
        }
        #zen-reader-root {
          position: relative;
          z-index: 1;
          max-width: var(--zen-reader-measure);
          margin: 0 auto;
          padding: var(--zen-reader-pad-top) 22px var(--zen-reader-pad-bottom);
          box-sizing: border-box;
        }
        #zen-reader-highlights {
          position: absolute;
          top: 0; left: 0;
          width: 100%;
          height: 0;
          z-index: 0;
          pointer-events: none;
        }
        .zen-reader-hl {
          position: absolute;
          background: var(--zen-reader-highlight);
          border-radius: 3px;
          transition: opacity 120ms ease-out;
        }
        #zen-reader-header { margin-bottom: 1.6em; }
        .zen-reader-site {
          margin: 0 0 0.5em;
          font-size: 0.72em;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--zen-reader-secondary);
        }
        .zen-reader-title {
          margin: 0 0 0.35em;
          font-size: 1.85em;
          line-height: 1.16;
          font-weight: 700;
          letter-spacing: -0.012em;
        }
        .zen-reader-byline, .zen-reader-meta {
          margin: 0 0 0.25em;
          font-size: 0.82em;
          line-height: 1.4;
          color: var(--zen-reader-secondary);
        }
        #zen-reader-header::after {
          content: "";
          display: block;
          margin-top: 1.2em;
          border-bottom: 1px solid var(--zen-reader-border);
        }
        #zen-reader-content {
          text-align: var(--zen-reader-align);
          -webkit-hyphens: var(--zen-reader-hyphens);
          hyphens: var(--zen-reader-hyphens);
          overflow-wrap: break-word;
        }
        #zen-reader-content p,
        #zen-reader-content ul,
        #zen-reader-content ol,
        #zen-reader-content blockquote,
        #zen-reader-content pre,
        #zen-reader-content figure,
        #zen-reader-content table {
          margin: 0 0 var(--zen-reader-para-space);
        }
        #zen-reader-content h1,
        #zen-reader-content h2,
        #zen-reader-content h3,
        #zen-reader-content h4 {
          line-height: 1.25;
          margin: 1.5em 0 0.5em;
          text-align: left;
          -webkit-hyphens: manual;
          hyphens: manual;
        }
        #zen-reader-content h1 { font-size: 1.45em; }
        #zen-reader-content h2 { font-size: 1.28em; }
        #zen-reader-content h3 { font-size: 1.12em; }
        #zen-reader-content h4 { font-size: 1em; }
        #zen-reader-content a {
          color: var(--zen-reader-link);
          text-decoration: underline;
          text-underline-offset: 0.16em;
          text-decoration-thickness: 0.06em;
        }
        #zen-reader-content img,
        #zen-reader-content video,
        #zen-reader-content svg {
          max-width: 100%;
          height: auto;
          border-radius: 6px;
          display: block;
          margin: 0 auto;
        }
        #zen-reader-content figcaption {
          font-size: 0.78em;
          color: var(--zen-reader-secondary);
          text-align: center;
          margin-top: 0.5em;
        }
        #zen-reader-content blockquote {
          padding-left: 1em;
          border-left: 3px solid var(--zen-reader-border);
          color: var(--zen-reader-secondary);
          font-style: italic;
        }
        #zen-reader-content pre,
        #zen-reader-content code {
          font-family: ui-monospace, 'SF Mono', Menlo, monospace;
          font-size: 0.86em;
          letter-spacing: 0;
        }
        #zen-reader-content pre {
          padding: 0.85em 1em;
          border-radius: 8px;
          overflow-x: auto;
          background: var(--zen-reader-border);
          text-align: left;
        }
        #zen-reader-content hr {
          border: none;
          border-top: 1px solid var(--zen-reader-border);
          margin: 2em 0;
        }
        #zen-reader-content table {
          width: 100%;
          border-collapse: collapse;
          font-size: 0.9em;
        }
        #zen-reader-content th,
        #zen-reader-content td {
          border: 1px solid var(--zen-reader-border);
          padding: 0.4em 0.6em;
          text-align: left;
        }
        #zen-reader-footer {
          margin-top: 2.4em;
          padding-top: 1.2em;
          border-top: 1px solid var(--zen-reader-border);
          font-size: 0.72em;
          color: var(--zen-reader-secondary);
        }
        html.zen-no-images #zen-reader-content img,
        html.zen-no-images #zen-reader-content picture,
        html.zen-no-images #zen-reader-content figure,
        html.zen-no-images #zen-reader-content video,
        html.zen-no-images #zen-reader-content svg { display: none !important; }
        html.zen-drop-caps #zen-reader-content > p:first-of-type::first-letter {
          float: left;
          font-size: 3.1em;
          line-height: 0.84;
          padding: 0.04em 0.09em 0 0;
          font-weight: 700;
        }
        """

    // MARK: The page's own script

    /// Three jobs: index the text so Swift can talk about offsets, report
    /// scroll progress, and draw the read-aloud highlight.
    private static let pageScript = """
        (function () {
          var handler = window.webkit && window.webkit.messageHandlers
            ? window.webkit.messageHandlers.\(messageHandlerName) : null;
          function post(message) { try { if (handler) handler.postMessage(message); } catch (e) {} }

          // --- Text index -------------------------------------------------
          // A flat list of the article's text nodes with the UTF-16 offset each
          // one starts at, plus the concatenation. Swift chunks *that* string
          // into sentences, so an offset pair always maps back to a real Range.
          var nodes = [];
          var fullText = "";
          function buildIndex() {
            nodes = [];
            fullText = "";
            var root = document.getElementById("zen-reader-content");
            if (!root) { return; }
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            var node;
            while ((node = walker.nextNode())) {
              var value = node.nodeValue;
              if (!value) { continue; }
              nodes.push({ node: node, start: fullText.length, length: value.length });
              fullText += value;
            }
          }

          function rangeFor(start, end) {
            if (!nodes.length || end <= start) { return null; }
            var range = document.createRange();
            var placedStart = false;
            for (var i = 0; i < nodes.length; i++) {
              var entry = nodes[i];
              var entryEnd = entry.start + entry.length;
              if (!placedStart && start < entryEnd) {
                range.setStart(entry.node, Math.max(0, start - entry.start));
                placedStart = true;
              }
              if (placedStart && end <= entryEnd) {
                range.setEnd(entry.node, Math.max(0, end - entry.start));
                return range;
              }
            }
            if (!placedStart) { return null; }
            var last = nodes[nodes.length - 1];
            range.setEnd(last.node, last.length);
            return range;
          }

          // --- Highlight --------------------------------------------------
          var current = null;
          function clearHighlight() {
            var layer = document.getElementById("zen-reader-highlights");
            if (layer) { layer.innerHTML = ""; }
          }
          function draw() {
            clearHighlight();
            var layer = document.getElementById("zen-reader-highlights");
            if (!layer || !current) { return; }
            var range = rangeFor(current[0], current[1]);
            if (!range) { return; }
            var rects = range.getClientRects();
            var offsetX = window.scrollX || 0;
            var offsetY = window.scrollY || 0;
            for (var i = 0; i < rects.length; i++) {
              var rect = rects[i];
              if (rect.width < 1 || rect.height < 1) { continue; }
              var box = document.createElement("div");
              box.className = "zen-reader-hl";
              box.style.left = (rect.left + offsetX - 2) + "px";
              box.style.top = (rect.top + offsetY - 1) + "px";
              box.style.width = (rect.width + 4) + "px";
              box.style.height = (rect.height + 2) + "px";
              layer.appendChild(box);
            }
          }
          window.zenReaderRedrawHighlight = draw;

          window.zenReaderHighlight = function (start, end, follow) {
            current = [start, end];
            draw();
            if (follow) {
              var range = rangeFor(start, end);
              if (range) {
                var rect = range.getBoundingClientRect();
                var margin = window.innerHeight * 0.3;
                if (rect.top < margin || rect.bottom > window.innerHeight - margin) {
                  window.scrollTo({
                    top: rect.top + (window.scrollY || 0) - margin,
                    behavior: "smooth"
                  });
                }
              }
            }
            return true;
          };

          window.zenReaderClearHighlight = function () {
            current = null;
            clearHighlight();
            return true;
          };

          // --- Progress ---------------------------------------------------
          var ticking = false;
          function progress() {
            var scrollable = Math.max(
              1, document.documentElement.scrollHeight - window.innerHeight);
            return Math.min(1, Math.max(0, (window.scrollY || 0) / scrollable));
          }
          function reportProgress() {
            post({ type: "progress", value: progress() });
          }
          window.addEventListener("scroll", function () {
            if (ticking) { return; }
            ticking = true;
            window.requestAnimationFrame(function () {
              ticking = false;
              reportProgress();
            });
          }, { passive: true });

          window.zenReaderScrollTo = function (fraction) {
            var scrollable = Math.max(
              1, document.documentElement.scrollHeight - window.innerHeight);
            window.scrollTo({ top: scrollable * fraction, behavior: "auto" });
            return true;
          };

          window.addEventListener("resize", function () { draw(); reportProgress(); });

          buildIndex();
          post({ type: "ready", text: fullText });
          reportProgress();
        })();
        """

    // MARK: Escaping

    /// Titles and bylines come out of a web page and go into our markup.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// A single-quoted JavaScript string literal. Font stacks contain quotes
    /// ('SF Mono'), which is exactly the case that breaks naive interpolation.
    static func jsString(_ value: String) -> String {
        var out = "'"
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.append(character)
            }
        }
        return out + "'"
    }

    /// `19.0` reads as a font size; `19` reads as a decision. Drops the
    /// fraction where there is not one, and never emits exponent notation.
    static func trim(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.3g", value)
    }
}
