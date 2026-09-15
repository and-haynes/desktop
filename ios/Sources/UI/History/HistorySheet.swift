//  HistorySheet.swift
//  History, bookmarks and Local, with search.
//
//  Local sits beside the other two because it is the same kind of thing: a list
//  of places you can get to. On a home network it is the list you use most, and
//  burying it in Settings would have meant a trip through Settings every time
//  (#0089C).

import SwiftUI

struct HistorySheet: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var history: HistoryStore
    @ObservedObject var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var query = ""
    @State private var tab: Section = .history

    enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case bookmarks = "Bookmarks"
        case local = "Local"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .history: historyList
                case .bookmarks: bookmarksList
                case .local:
                    LocalServicesList(
                        state: state, store: state.localServices, query: query,
                        onOpen: { dismiss() }
                    )
                    .environment(\.zenPalette, palette)
                }
            }
            .searchable(text: $query, prompt: "Search \(tab.rawValue.lowercased())")
            .navigationTitle(tab.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $tab) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityIdentifier("historySectionPicker")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if tab == .history && !history.entries.isEmpty {
                        Button(role: .destructive) {
                            history.clearAll()
                        } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Clear history")
                    }
                }
            }
        }
        .tint(palette.accent.color)
    }

    private var filteredHistory: [HistoryEntry] {
        guard !query.isEmpty else { return history.entries }
        return history.suggestions(for: query, limit: 200)
    }

    private var historyList: some View {
        List {
            if filteredHistory.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No history yet" : "No matches",
                    systemImage: "clock.arrow.circlepath")
            }
            ForEach(filteredHistory) { entry in
                Button {
                    open(entry.url)
                } label: {
                    row(title: entry.displayTitle, subtitle: entry.url.absoluteString, date: entry.lastVisited)
                }
                .swipeActions {
                    Button(role: .destructive) { history.remove(entry) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredBookmarks: [Bookmark] {
        guard !query.isEmpty else { return bookmarks.bookmarks }
        let needle = query.lowercased()
        return bookmarks.bookmarks.filter {
            $0.title.lowercased().contains(needle)
                || $0.url.absoluteString.lowercased().contains(needle)
        }
    }

    private var bookmarksList: some View {
        List {
            if filteredBookmarks.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No bookmarks yet" : "No matches", systemImage: "bookmark")
            }
            ForEach(filteredBookmarks) { bookmark in
                Button {
                    open(bookmark.url)
                } label: {
                    row(
                        title: bookmark.title, subtitle: bookmark.url.absoluteString,
                        date: bookmark.createdAt)
                }
                .swipeActions {
                    Button(role: .destructive) { bookmarks.remove(bookmark) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(title: String, subtitle: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(date, style: .relative)
                    .layoutPriority(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func open(_ url: URL) {
        if let tabID = state.activeTabID {
            state.updateTab(tabID) { tab in
                tab.url = url
                tab.title = ""
                tab.scrollY = 0
            }
        } else {
            state.newTab(url: url)
        }
        dismiss()
    }
}
