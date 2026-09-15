//  TextSizeControl.swift
//  The text-size row in the More menu, its keyboard equivalents, and the one
//  place a zoom change actually happens (#008B7).
//
//  Safari puts *smaller* and *larger* side by side on one row with the current
//  percentage between them, and that shape is worth copying exactly: two
//  glyphs stacked vertically would be two menu rows spent on one idea, and a
//  slider in a menu is a thing nobody can hit. `ControlGroup` inside a `Menu`
//  is SwiftUI's own name for that row.
//
//  The change itself goes out as a notification rather than being applied
//  here, for the same reason reload and the navigation verbs do: only
//  `RootView` holds the web view pool, and the menu is drawn several layers
//  below it. That also means the menu, the keyboard and anything added later
//  share one code path — see `PageZoomBridge`.

import SwiftUI
import WebKit

/// What a zoom request means. Three verbs rather than a target value: the
/// ladder lives in `PageZoom`, and a caller that had to know the next step
/// would be a second copy of it.
enum PageZoomChange: String, Sendable {
    case larger
    case smaller
    /// Forget this site's override, so it follows the global default again.
    case reset
}

extension Notification.Name {
    /// Change the zoom of the page in `userInfo["tab"]`, or of the active one.
    /// `userInfo["change"]` is a `PageZoomChange` raw value.
    static let zenChangePageZoom = Notification.Name("zen.changePageZoom")
}

enum PageZoomCommand {
    static func post(_ change: PageZoomChange, tabID: UUID? = nil) {
        var info: [String: String] = ["change": change.rawValue]
        if let tabID { info["tab"] = tabID.uuidString }
        NotificationCenter.default.post(name: .zenChangePageZoom, object: nil, userInfo: info)
    }

    /// The new level for a change, or nil for "reset" — which is an absence,
    /// not a number. Pure, so the ladder can be tested without a web view.
    static func resolve(_ change: PageZoomChange, current: Double) -> Double? {
        switch change {
        case .larger: return PageZoom.larger(than: current)
        case .smaller: return PageZoom.smaller(than: current)
        case .reset: return nil
        }
    }

    /// Apply a change to one site's stored level and report the level the page
    /// should now be shown at. The store is the only thing mutated; putting
    /// the number on a `WKWebView` is the caller's job.
    @discardableResult
    @MainActor
    static func apply(
        _ change: PageZoomChange, url: URL?, store: PageZoomStore, default globalDefault: Double
    ) -> Double {
        let current = store.zoom(for: url, default: globalDefault)
        guard let next = resolve(change, current: current) else {
            store.reset(url)
            return store.zoom(for: url, default: globalDefault)
        }
        // At either end of the ladder nothing moves, and a haptic for a change
        // that did not happen is the phone lying to you.
        guard abs(next - current) > 0.0001 else { return current }
        store.set(next, for: url)
        Haptics.shared.fire(.textSizeStep)
        return next
    }
}

// MARK: - The menu row

/// `ControlGroup` — smaller / larger side by side — plus the readout, which is
/// also the reset. Drawn inside a `Menu`'s content, so it is a *section* of the
/// More menu rather than a view with a frame of its own.
struct TextSizeMenuSection: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var zoom: PageZoomStore
    /// Which pane's page this is about. nil means the active tab.
    var tabID: UUID?

    private var url: URL? {
        let tab = tabID.flatMap { state.tab(id: $0) } ?? state.activeTab
        guard let tab, !tab.isNewTabPage else { return nil }
        return tab.url
    }

    private var current: Double {
        zoom.zoom(for: url, default: state.settings.defaultPageZoom)
    }

    var body: some View {
        ControlGroup {
            Button {
                PageZoomCommand.post(.smaller, tabID: tabID)
            } label: {
                Label("Smaller", systemImage: "textformat.size.smaller")
            }
            .disabled(url == nil || PageZoom.isAtMinimum(current))
            .accessibilityIdentifier("textSizeSmaller")

            Button {
                PageZoomCommand.post(.larger, tabID: tabID)
            } label: {
                Label("Larger", systemImage: "textformat.size.larger")
            }
            .disabled(url == nil || PageZoom.isAtMaximum(current))
            .accessibilityIdentifier("textSizeLarger")
        }

        // The readout doubles as the reset, which is why it is a button and
        // not a `Text`: a percentage you cannot undo is a number that stares
        // at you.
        Button {
            PageZoomCommand.post(.reset, tabID: tabID)
        } label: {
            Label(
                "Text size \(PageZoom.percentLabel(current))",
                systemImage: zoom.hasOverride(for: url)
                    ? "arrow.counterclockwise" : "textformat.size")
        }
        .disabled(url == nil || !zoom.hasOverride(for: url))
        .accessibilityIdentifier("textSizeReadout")
    }
}

// MARK: - Hardware keyboard

/// ⌘+ / ⌘− / ⌘0, as the invisible buttons SwiftUI needs to hang a shortcut on.
/// Its own view rather than three more lines in `RootView.keyboardShortcuts`:
/// that `ZStack` is already as long as the type checker will sit still for.
///
/// `⌘+` is really `⌘=` on a US layout — the plus is a shifted equals — so both
/// are bound, which is what every other browser does.
struct PageZoomShortcuts: View {
    var body: some View {
        ZStack {
            shortcut("=") { PageZoomCommand.post(.larger) }
            shortcut("+") { PageZoomCommand.post(.larger) }
            shortcut("-") { PageZoomCommand.post(.smaller) }
            shortcut("0") { PageZoomCommand.post(.reset) }
        }
    }

    private func shortcut(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("") {
            Haptics.shared.fire(.shortcut)
            action()
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}

// MARK: - Applying it

/// Keeps live web views at the level their site is remembered at. A modifier
/// rather than more `onReceive`s on `RootView`, which is the documented remedy
/// for that view's modifier chain — and it is the only thing in the tree that
/// can reach both the pool and the store.
struct PageZoomBridge: ViewModifier {
    @ObservedObject var state: BrowserState
    let pool: WebViewPool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .zenChangePageZoom)) { note in
                handle(note)
            }
            // Changing the global default has to move every page that has no
            // opinion of its own, not just the next one loaded.
            .onChange(of: state.settings.defaultPageZoom) { _, _ in applyToAll() }
    }

    private func handle(_ note: Notification) {
        let raw = note.userInfo?["change"] as? String ?? ""
        guard let change = PageZoomChange(rawValue: raw) else { return }
        let tabID =
            (note.userInfo?["tab"] as? String).flatMap(UUID.init(uuidString:))
            ?? state.activeTabID
        guard let tabID, let tab = state.tab(id: tabID), !tab.isNewTabPage else { return }
        let level = PageZoomCommand.apply(
            change, url: tab.url, store: state.pageZoom,
            default: state.settings.defaultPageZoom)
        pool.existing(for: tabID)?.applyPageZoom(level)
        // Two panes on the same site should not disagree about how big it is.
        applyToAll()
    }

    private func applyToAll() {
        for view in pool.loadedViews {
            guard let id = view.tabID, let tab = state.tab(id: id) else { continue }
            view.applyPageZoom(
                state.pageZoom.zoom(for: tab.url, default: state.settings.defaultPageZoom))
        }
    }
}

extension WKWebView {
    /// Set `pageZoom`, skipping the write when it would not change anything —
    /// assigning it relays out the document, and this runs on every navigation
    /// and every settings change.
    func applyPageZoom(_ zoom: Double) {
        let next = PageZoom.clamp(zoom)
        guard abs(pageZoom - next) > 0.0001 else { return }
        pageZoom = next
        // `pageZoom` is a real zoom, not a text-only reflow, so a page with a
        // fixed-width column becomes wider than the window and WebKit leaves
        // the horizontal offset wherever the growth put it — which reads as
        // the page having jumped sideways. Pin it back to the left edge; the
        // page is still scrollable by hand from there.
        scrollView.contentOffset.x = 0
    }
}
