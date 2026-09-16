//  ReaderController.swift
//  One article, being read: the settings in force, the page's scroll progress,
//  and the voice reading it aloud (#008BC).
//
//  This is the only object that knows all three at once, which is why the
//  highlight works: the synthesizer says "sentence 14", the chunker says where
//  sentence 14 is in the indexed text, and the reader page turns that pair of
//  offsets into rectangles.
//
//  Settings changes take two different routes on purpose. Restyling is
//  immediate — a slider that lags is a slider you cannot aim — but *writing*
//  the per-site memory is debounced, because a drag produces sixty changes a
//  second and each one would be a file write.

import Combine
import Foundation
import WebKit

@MainActor
final class ReaderController: NSObject, ObservableObject {

    // MARK: State

    @Published private(set) var article: ReaderArticle?
    /// The settings in force for the article on screen. Assigning restyles the
    /// page and (eventually) remembers the choice for this site.
    @Published var settings = ReaderSettings() {
        didSet {
            guard settings != oldValue else { return }
            applySettings()
            speech.rate = settings.speechRate
            scheduleSiteSave()
        }
    }
    /// 0...1, from the reader page's own scroll position.
    @Published private(set) var progress: Double = 0
    @Published var isPanelPresented = false
    /// The read-aloud transport, shown once you have asked for it.
    @Published var isReadAloudVisible = false
    /// Set while an extraction is in flight, so the button can say so.
    @Published private(set) var isExtracting = false

    let speech = ReaderSpeech()
    let sites: ReaderSiteStore

    /// What a site with no opinion of its own falls back to.
    private(set) var globalDefaults = ReaderSettings()
    private(set) var insets = ReaderInsets()

    /// The reader's own web view, once the representable has made one.
    weak var webView: WKWebView?
    /// A link tapped inside the reader leaves it — handed back to the browser.
    var onOpenLink: ((URL) -> Void)?

    private var siteSaveTask: Task<Void, Never>?
    /// Set while the controller is deliberately dropping a site's override, so
    /// the assignment that does it is not itself remembered.
    private var isForgetting = false

    init(sites: ReaderSiteStore? = nil) {
        self.sites = sites ?? .shared
        super.init()
        speech.onSentence = { [weak self] sentence in
            self?.highlight(sentence)
        }
    }

    // MARK: Opening

    /// Take an extracted article and the browser's global defaults, and settle
    /// on the settings this particular site should be read at.
    func open(_ article: ReaderArticle, defaults: ReaderSettings) {
        globalDefaults = defaults.clamped()
        self.article = article
        progress = 0
        isReadAloudVisible = false
        speech.stop()
        speech.language = article.language.isEmpty ? nil : article.language
        // Assigned through the property so the didSet path is the only one
        // that ever sets `settings` — except that here there is no page yet to
        // restyle and nothing new to persist, so the write is cancelled after.
        settings = sites.settings(for: article.url, default: globalDefaults)
        siteSaveTask?.cancel()
        speech.rate = settings.speechRate
    }

    func close() {
        speech.stop()
        siteSaveTask?.cancel()
        siteSaveTask = nil
        article = nil
        progress = 0
        isPanelPresented = false
        isReadAloudVisible = false
        webView = nil
    }

    func setExtracting(_ extracting: Bool) { isExtracting = extracting }

    /// Whether this site is being read on its own terms rather than the
    /// browser's — what lets the panel offer "Use my defaults" only when there
    /// is something to undo.
    var hasSiteOverride: Bool { sites.hasOverride(for: article?.url) }

    var siteKey: String? { ReaderSite.siteKey(for: article?.url) }

    /// Drop this site's override and go back to the global default.
    ///
    /// `isForgetting` is what stops the assignment below immediately writing
    /// the override back: the point of this button is to leave no entry at all,
    /// so that the site follows whatever the default becomes later.
    func useGlobalDefaults() {
        isForgetting = true
        settings = globalDefaults
        isForgetting = false
        siteSaveTask?.cancel()
        siteSaveTask = nil
        sites.reset(article?.url)
        applySettings()
    }

    /// Make this article's settings the browser-wide default. Returns them so
    /// the caller can write them into `ZenSettings` — the controller does not
    /// own the session.
    func adoptAsDefaults() -> ReaderSettings {
        globalDefaults = settings
        return settings
    }

    // MARK: The page

    /// The document to load. Nil before an article has been extracted.
    func document() -> String? {
        guard let article else { return nil }
        return ReaderTemplate.document(article: article, settings: settings, insets: insets)
    }

    /// Chrome heights change with the device and with whether the read-aloud
    /// bar is up; the page needs to know so its first and last lines are not
    /// underneath them.
    func setInsets(_ newInsets: ReaderInsets) {
        guard newInsets != insets else { return }
        insets = newInsets
        applySettings()
    }

    /// Push the current settings into a live page. Cheap — a handful of custom
    /// properties and two class toggles, then a repaint.
    func applySettings() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            ReaderTemplate.applyScript(for: settings, insets: insets), completionHandler: nil)
    }

    // MARK: Messages from the page

    /// The page finished building its text index. That string — not
    /// Readability's `textContent` — is what read-aloud is chunked from, so an
    /// offset always maps back onto a real range in the rendered DOM.
    func pageBecameReady(indexedText: String) {
        let sentences = ReaderSpeechChunker.sentences(in: indexedText)
        speech.load(sentences)
        speech.rate = settings.speechRate
        applySettings()
    }

    func pageDidScroll(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        guard abs(clamped - progress) > 0.0005 else { return }
        progress = clamped
    }

    private func highlight(_ sentence: ReaderSentence?) {
        guard let webView else { return }
        guard let sentence else {
            webView.evaluateJavaScript("window.zenReaderClearHighlight()", completionHandler: nil)
            return
        }
        webView.evaluateJavaScript(
            "window.zenReaderHighlight(\(sentence.start), \(sentence.end), true)",
            completionHandler: nil)
    }

    // MARK: Per-site memory

    /// A drag is sixty changes a second and a JSON write is not free. Wait for
    /// the hand to stop before remembering anything.
    private func scheduleSiteSave() {
        guard !isForgetting, let url = article?.url else { return }
        let value = settings
        siteSaveTask?.cancel()
        siteSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.sites.set(value, for: url)
        }
    }
}

// MARK: - The page talking back

extension ReaderController: WKScriptMessageHandler {
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else { return }
        switch type {
        case "ready": pageBecameReady(indexedText: body["text"] as? String ?? "")
        case "progress": pageDidScroll(to: body["value"] as? Double ?? 0)
        default: break
        }
    }
}
