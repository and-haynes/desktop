//  BrowserState+Sync.swift
//  The seam between the browser model and the sync engines.
//
//  Kept as an extension in the Sync directory rather than as fields on
//  `Space` and `Tab` so the model stays unaware that sync exists: everything
//  sync needs is either derivable from the model or lives in the sync
//  shadow's identity map.

import Foundation

extension BrowserState {

    /// The slice the spaces engine merges.
    var spacesState: SpacesState {
        SpacesState(spaces: spaces, tabs: tabs)
    }

    /// Adopt a merged state. Selection is repaired rather than preserved
    /// blindly: a sync can remove the tab that was selected, and leaving a
    /// dangling pointer shows an empty frame.
    func applySyncedSpacesState(_ merged: SpacesState) {
        guard merged.spaces != spaces || merged.tabs != tabs else { return }

        // Never let a sync leave the browser with no space to be in.
        guard !merged.spaces.isEmpty else { return }

        let liveTabs = Set(tabs.filter(\.isLoaded).map(\.id))
        setSpaces(merged.spaces)
        setTabs(
            merged.tabs.map { tab in
                var tab = tab
                // A web view already exists for these; the merge does not know
                // that, and clearing the flag would orphan the view.
                tab.isLoaded = liveTabs.contains(tab.id)
                return tab
            })
        repairSelection()
        scheduleSave()
    }
}

extension BookmarkStore {
    /// Apply a bookmarks merge. Additions go to the top, matching the order a
    /// locally-made bookmark appears in.
    func applySynced(added: [Bookmark], updated: [Bookmark], removedIDs: [UUID]) {
        guard !added.isEmpty || !updated.isEmpty || !removedIDs.isEmpty else { return }
        var merged = bookmarks
        let doomed = Set(removedIDs)
        merged.removeAll { doomed.contains($0.id) }
        for bookmark in updated {
            if let index = merged.firstIndex(where: { $0.id == bookmark.id }) {
                merged[index] = bookmark
            }
        }
        // A bookmark the other device already had is not a new one here.
        let known = Set(merged.map(\.url))
        merged.insert(contentsOf: added.filter { !known.contains($0.url) }, at: 0)
        replaceAll(with: merged)
    }
}

extension HistoryStore {
    /// Fold another device's visits in. A page we already know keeps the later
    /// of the two timestamps and the larger visit count — history is additive,
    /// and last-writer-wins would quietly delete evidence of a visit.
    func applySynced(_ visits: [HistoryEngine.IncomingVisit]) {
        guard !visits.isEmpty else { return }
        var merged = entries
        var index: [URL: Int] = [:]
        for (position, entry) in merged.enumerated() { index[entry.url] = position }

        for visit in visits {
            if let position = index[visit.url] {
                merged[position].lastVisited = max(merged[position].lastVisited, visit.lastVisited)
                merged[position].visitCount = max(merged[position].visitCount, visit.visitCount)
                if merged[position].title.isEmpty { merged[position].title = visit.title }
            } else {
                merged.append(
                    HistoryEntry(
                        url: visit.url, title: visit.title, lastVisited: visit.lastVisited,
                        visitCount: visit.visitCount))
            }
        }
        merged.sort { $0.lastVisited > $1.lastVisited }
        if merged.count > HistoryStore.maxEntries {
            merged.removeLast(merged.count - HistoryStore.maxEntries)
        }
        replaceAll(with: merged)
    }
}
