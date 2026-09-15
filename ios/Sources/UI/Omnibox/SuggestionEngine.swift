//  SuggestionEngine.swift
//  Merges the three result sources Zen's urlbar shows: what you typed, your
//  history, and the search engine's autocomplete.
//
//  Upstream also contributes a large set of "global actions" (toggle compact
//  mode, next space, new split …) through ZenUBGlobalActions. We ship the
//  subset that exists on iOS.

import Foundation
import SwiftUI

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Commit exactly what is typed.
        case topHit
        case history(URL)
        case searchTerm
        /// A bare word read as a hostname — the explicit second option when
        /// `meitner` could mean either thing.
        case goToHost(URL)
        /// One of Zen's urlbar actions.
        case action(OmniboxAction)
        /// A service imported from a LAN scan (#0089C). Aliases are the point:
        /// `proxmox` should be something you can type.
        case localService(URL)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var faviconData: Data?
}

/// The Zen urlbar actions that mean something on a phone.
enum OmniboxAction: String, CaseIterable, Equatable {
    case toggleCompactMode
    case newSplitView
    case unsplitView
    case newSpace
    case copyCurrentURL
    case nextSpace
    case previousSpace
    case closeTab
    case duplicateTab
    case reloadTab
    case findInPage
    case toggleDesktopSite
    case openSettings
    case openHistory

    var title: String {
        switch self {
        case .toggleCompactMode: return "Toggle Compact Mode"
        case .newSplitView: return "New Split View"
        case .unsplitView: return "Unsplit View"
        case .newSpace: return "New Space"
        case .copyCurrentURL: return "Copy Current URL"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .closeTab: return "Close Tab"
        case .duplicateTab: return "Duplicate Tab"
        case .reloadTab: return "Reload Tab"
        case .findInPage: return "Find in Page"
        case .toggleDesktopSite: return "Toggle Desktop Site"
        case .openSettings: return "Settings"
        case .openHistory: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .toggleCompactMode: return "rectangle.compress.vertical"
        case .newSplitView, .unsplitView: return "rectangle.split.2x1"
        case .newSpace: return "square.stack.3d.up"
        case .copyCurrentURL: return "doc.on.doc"
        case .nextSpace: return "arrow.right.square"
        case .previousSpace: return "arrow.left.square"
        case .closeTab: return "xmark.square"
        case .duplicateTab: return "plus.square.on.square"
        case .reloadTab: return "arrow.clockwise"
        case .findInPage: return "text.magnifyingglass"
        case .toggleDesktopSite: return "desktopcomputer"
        case .openSettings: return "gearshape"
        case .openHistory: return "clock.arrow.circlepath"
        }
    }

    @MainActor
    func isAvailable(in state: BrowserState) -> Bool {
        switch self {
        case .unsplitView: return state.isSplitActive
        case .newSplitView: return !state.isSplitActive
        case .nextSpace, .previousSpace: return state.spaces.count > 1
        case .copyCurrentURL, .closeTab, .duplicateTab, .reloadTab, .findInPage:
            return state.activeTab != nil
        default: return true
        }
    }
}

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var suggestions: [Suggestion] = []

    private var fetchTask: Task<Void, Never>?
    /// `MINIMUM_QUERY_SCORE` gates Zen's action matching at >2 characters.
    private let minimumActionQueryLength = 2

    func update(query rawQuery: String, state: BrowserState) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        fetchTask?.cancel()

        let engine = state.settings.searchEngine
        let knownHosts = state.knownSingleLabelHosts
        var results: [Suggestion] = []

        if query.isEmpty {
            // An empty box offers recent history, as Zen's does.
            results = state.history.suggestions(for: "", limit: 6).map(Self.historyRow)
            suggestions = results
            return
        }

        // 1. The top hit: what committing right now would do.
        //
        // An exact alias wins outright, because `OmniboxOverlay.commit` sends
        // it there — the top row's whole job is being an honest preview of
        // pressing Return, so the two check the same thing.
        let intent = URLDetector.intent(for: query, engine: engine, knownHosts: knownHosts)
        if let service = state.localServices.exactMatch(query) {
            results.append(
                Suggestion(
                    id: "top", kind: .localService(service.url), title: service.alias,
                    subtitle: "Local · \(service.addressLabel)", symbol: service.symbol))
            results += state.history.suggestions(for: query, limit: 3).map(Self.historyRow)
            results.append(
                Suggestion(
                    id: "go-search", kind: .searchTerm, title: query,
                    subtitle: "Search with \(engine.displayName)", symbol: engine.symbol))
            suggestions = results
            return
        }
        switch intent {
        case .navigate(let url):
            results.append(
                Suggestion(
                    id: "top", kind: .topHit, title: url.absoluteString,
                    subtitle: "Open link", symbol: "arrow.up.right"))
        case .search(let term):
            results.append(
                Suggestion(
                    id: "top", kind: .topHit, title: term,
                    subtitle: "Search with \(engine.displayName)", symbol: engine.symbol))
        }

        // 1b. The other reading of a bare word. `meitner` is a machine on
        // someone's network and `pottery` is a search, and nothing in the
        // string tells them apart — so rather than guessing, both are offered,
        // with whichever is *less* likely sitting second. Searching stays the
        // default for a word we have never been to; once you have been to
        // `meitner` the intent above flips and it is searching that moves down.
        if let label = URLDetector.singleLabelName(query),
            let hostURL = URLDetector.singleLabelURL(label)
        {
            switch intent {
            case .search:
                results.append(
                    Suggestion(
                        id: "go-host", kind: .goToHost(hostURL),
                        title: "Go to \(hostURL.absoluteString)",
                        subtitle: "Open as a network address", symbol: "network"))
            case .navigate:
                results.append(
                    Suggestion(
                        id: "go-search", kind: .searchTerm, title: label,
                        subtitle: "Search with \(engine.displayName)", symbol: engine.symbol))
            }
        }

        // 1c. Local services. Ranked above history because an alias is a name
        // *you chose* for something on this network — if `proxmox` matches a
        // service, that is what you meant, not a page you once visited whose
        // title happened to contain the word.
        results += state.localServices.suggestions(for: query, limit: 3).map(Self.localRow)

        // 2. History.
        results += state.history.suggestions(for: query, limit: 4).map(Self.historyRow)

        // 3. Zen actions, fuzzy-matched on the title.
        if query.count > minimumActionQueryLength {
            let needle = query.lowercased()
            results += OmniboxAction.allCases
                .filter { $0.isAvailable(in: state) && $0.title.lowercased().contains(needle) }
                .prefix(3)
                .map {
                    Suggestion(
                        id: "action-\($0.rawValue)", kind: .action($0), title: $0.title,
                        subtitle: "Zen action", symbol: $0.symbol)
                }
        }

        suggestions = results

        // 4. Remote autocomplete, folded in when it arrives.
        guard let url = engine.suggestionsURL(for: query) else { return }
        fetchTask = Task { [weak self] in
            let terms = await Self.fetchSuggestions(url)
            guard !Task.isCancelled, let self else { return }
            let rows = terms.prefix(5).enumerated().map { index, term in
                Suggestion(
                    id: "search-\(index)-\(term)", kind: .searchTerm, title: term,
                    subtitle: engine.displayName, symbol: "magnifyingglass")
            }
            // Re-check the query still matches; the user may have typed on.
            guard self.suggestions.first?.kind == .topHit else { return }
            self.suggestions = results + rows
        }
    }

    func clear() {
        fetchTask?.cancel()
        suggestions = []
    }

    private static func localRow(_ service: LocalService) -> Suggestion {
        Suggestion(
            id: "local-\(service.id.uuidString)", kind: .localService(service.url),
            title: service.alias, subtitle: service.addressLabel, symbol: service.symbol)
    }

    private static func historyRow(_ entry: HistoryEntry) -> Suggestion {
        Suggestion(
            id: "history-\(entry.id.uuidString)", kind: .history(entry.url),
            title: entry.displayTitle, subtitle: URLDetector.prettyHost(entry.url),
            symbol: "clock")
    }

    /// All five engines speak the OpenSearch JSON shape `["query", [...]]`.
    private static func fetchSuggestions(_ url: URL) async -> [String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = json as? [Any], array.count > 1, let terms = array[1] as? [String] {
            return terms
        }
        // DuckDuckGo's `type=list` sometimes answers with [{phrase: …}].
        if let objects = json as? [[String: Any]] {
            return objects.compactMap { $0["phrase"] as? String }
        }
        return []
    }
}
