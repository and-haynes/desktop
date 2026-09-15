//  NavigationHelper.swift
//  Page up / page down / top / bottom, as four buttons that appear while the
//  page is moving and go away when it settles (#008B9).
//
//  A long page on a phone is the one place touch is worse than a keyboard: a
//  flick moves an unpredictable distance, and getting back to the top means a
//  dozen of them or a tap on a status bar that this browser hides by default.
//  Desktop has Page Down; this is it.
//
//  Three decisions worth writing down:
//
//  1. **They are not always there.** Four permanent buttons over the page would
//     be four buttons covering somebody's content for the 99 % of the time they
//     are reading rather than paging. They fade in while the page is scrolling
//     and fade out on the same still-delay compact mode already uses, so there
//     is one number in Settings rather than two.
//  2. **They never take the first gesture.** They are not on screen when a
//     scroll begins and they do not hit-test while hidden, so the flick that
//     summons them is the flick that scrolls the page — a helper you have to
//     fight is worse than no helper.
//  3. **The step is a *visible page*, not a constant.** One screenful minus a
//     small overlap, so the line you were reading is still there after the tap.
//     That is the same rule every desktop browser's Page Down follows and the
//     reason it never loses your place.
//
//  The countdown runs on the same injected clock compact mode uses, so the
//  state machine is testable in microseconds.

import SwiftUI

// MARK: - What a button does

enum PageScrollStep: String, CaseIterable, Identifiable, Sendable {
    case top
    case pageUp
    case pageDown
    case bottom

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .top: return "arrow.up.to.line"
        case .pageUp: return "chevron.up"
        case .pageDown: return "chevron.down"
        case .bottom: return "arrow.down.to.line"
        }
    }

    var title: String {
        switch self {
        case .top: return "Scroll to top"
        case .pageUp: return "Page up"
        case .pageDown: return "Page down"
        case .bottom: return "Scroll to bottom"
        }
    }

    /// Top to bottom as they are stacked: the two ends on the outside, the two
    /// page steps in the middle, each pointing the way it moves.
    static let stacked: [PageScrollStep] = [.top, .pageUp, .pageDown, .bottom]
}

/// The arithmetic, with no scroll view in sight so it can be tested.
enum PageScroll {

    /// How much of the previous screenful survives a page step. Enough to
    /// carry a line of text and its context; not so much that three taps stop
    /// making progress.
    static let overlap: CGFloat = 44

    /// The floor on a step. A viewport shorter than the overlap — a pane
    /// squeezed to nothing in split view — would otherwise step by zero or
    /// backwards.
    static let minimumStride: CGFloat = 60

    /// One page: what you can see of the document, less the overlap.
    ///
    /// "What you can see" is the scroll view's height *minus its insets*, not
    /// its bounds: this browser routinely inserts 80pt of bar and island, and
    /// paging by the bounds would scroll that much content behind the chrome
    /// on every tap.
    static func stride(
        viewportHeight: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0
    ) -> CGFloat {
        max(minimumStride, viewportHeight - topInset - bottomInset - overlap)
    }

    /// The lowest legal content offset — where "scrolled to the top" is.
    static func minimumOffset(topInset: CGFloat) -> CGFloat { -topInset }

    /// The highest legal content offset. Never below the minimum: a document
    /// shorter than the window has exactly one valid position.
    static func maximumOffset(
        contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat
    ) -> CGFloat {
        max(
            minimumOffset(topInset: topInset),
            contentHeight - viewportHeight + bottomInset)
    }

    /// Where a step lands, clamped into the scrollable range.
    static func target(
        _ step: PageScrollStep, from offset: CGFloat, viewportHeight: CGFloat,
        contentHeight: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0
    ) -> CGFloat {
        let low = minimumOffset(topInset: topInset)
        let high = maximumOffset(
            contentHeight: contentHeight, viewportHeight: viewportHeight,
            topInset: topInset, bottomInset: bottomInset)
        let distance = stride(
            viewportHeight: viewportHeight, topInset: topInset, bottomInset: bottomInset)
        let proposed: CGFloat
        switch step {
        case .top: proposed = low
        case .bottom: proposed = high
        case .pageUp: proposed = offset - distance
        case .pageDown: proposed = offset + distance
        }
        return min(max(proposed, low), high)
    }
}

// MARK: - When they are on screen

/// Shown while the page moves, gone shortly after it stops.
///
/// Deliberately the same shape as `CompactBarController` — and the same clock
/// — because it answers the same question about the same events, and two
/// different answers to "has the page settled" would be visible as the bar and
/// the helper fading at different moments.
@MainActor
final class NavigationHelperController: ObservableObject {

    /// Whether the buttons are on screen *and* able to take a touch.
    @Published private(set) var isVisible: Bool = false

    /// Off by default — see the file comment. Switching it off takes the
    /// buttons away at once rather than on the next timer.
    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            clock.cancel()
            isVisible = false
        }
    }

    /// How long "still" is. Compact mode's number, so the chrome and the
    /// helper fade together.
    var stillDelay: TimeInterval = ZenSettings().compactHideDelay

    private let clock: CompactBarClock
    private let fire: @MainActor (HapticEvent) -> Void

    init(
        clock: CompactBarClock? = nil,
        fire: (@MainActor (HapticEvent) -> Void)? = nil
    ) {
        self.clock = clock ?? TaskCompactBarClock()
        self.fire = fire ?? { Haptics.shared.fire($0) }
    }

    // MARK: Events

    /// The page is moving. Brings the buttons in and stops any countdown — a
    /// long flick must not fade them out halfway through.
    func pageDidScroll() {
        guard isEnabled else { return }
        clock.cancel()
        isVisible = true
    }

    /// The page settled: everything from here is the still-timer.
    func scrollDidEnd() {
        guard isEnabled else { return }
        startCountdown()
    }

    /// A button was used. Keeps them for as long as you are paging — tapping
    /// Page Down four times in a row should not be a race against a timer.
    func stepTapped() {
        guard isEnabled else { return }
        // The page's own dismiss-tap is a `simultaneousGesture` on the view
        // these buttons are drawn over, so it fires for a touch on a button
        // too. Whichever of the two SwiftUI delivers first, the helper must
        // end up on screen: if this one lands first the flag eats the page
        // tap, and if the page tap lands first this call brings them back.
        ignoreNextPageTap = true
        isVisible = true
        fire(.navigationStep)
        startCountdown()
    }

    /// Set by `stepTapped`, consumed by the next `pageTapped`. See above.
    private var ignoreNextPageTap = false

    /// Something is covering the page: the omnibox, a sheet, the tab drawer.
    /// They go at once and do not come back until the page is scrolled again,
    /// because there is nothing behind the cover for them to page.
    func coveredDidChange(_ covered: Bool) {
        guard isEnabled, covered else { return }
        clock.cancel()
        isVisible = false
    }

    /// The page was tapped: put them away now rather than on the timer, as
    /// compact mode does with the chrome.
    func pageTapped() {
        guard isEnabled, isVisible else { return }
        guard !ignoreNextPageTap else {
            ignoreNextPageTap = false
            return
        }
        clock.cancel()
        isVisible = false
    }

    private func startCountdown() {
        guard isEnabled, isVisible else {
            clock.cancel()
            return
        }
        clock.schedule(after: max(0.2, stillDelay)) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.isVisible = false
        }
    }
}

// MARK: - Which side they sit on
//
// Resolving "Automatic" — the edge *opposite* the sidebar, because the
// sidebar's own edge already carries the drawer swipe and the bar's sidebar
// button — belongs to `EffectiveDisplay` since #008BB, so that a space which
// moved its sidebar moves the helper with it.

// MARK: - The buttons

/// Four minimal round buttons, stacked, in the bar's own fill.
///
/// Drawn over the *pane* rather than the window so a split shows them against
/// the page you are actually in — and so they clear a docked bar without
/// having to know anything about where the bar is.
struct NavigationHelperStack: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var helper: NavigationHelperController
    /// The pane this belongs to; the scroll goes to this tab's web view.
    var tabID: UUID?
    @Environment(\.zenPalette) private var palette

    /// A minimal target: big enough for the Apple minimum with the hit area
    /// around it, small enough not to be a toolbar down the side of the page.
    private static let diameter: CGFloat = 38
    private static let spacing: CGFloat = 8

    private var side: SidebarEdge { state.display.navigationHelperSide }
    private var fill: BarFill { state.display.resolvedBarFill }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(PageScrollStep.stacked) { step in
                button(step)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .opacity(helper.isVisible ? 1 : 0)
        // The whole point of (2) in the file comment: no touch reaches a
        // helper that is not on screen, so the flick that summons them is the
        // flick that scrolls.
        .allowsHitTesting(helper.isVisible)
        .animation(.easeInOut(duration: 0.22), value: helper.isVisible)
        .accessibilityHidden(!helper.isVisible)
    }

    private var alignment: Alignment {
        side == .leading ? .bottomLeading : .bottomTrailing
    }

    private func button(_ step: PageScrollStep) -> some View {
        Button {
            helper.stepTapped()
            PageScrollCommand.post(step, tabID: tabID ?? state.activeTabID)
        } label: {
            Image(systemName: step.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text.withAlpha(0.75).color)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .zenBarFill(
                    fill, palette: palette, isFloating: true, radius: Self.diameter / 2,
                    isInteractive: true)
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(step.title)
        .accessibilityIdentifier("navHelper-\(step.rawValue)")
    }
}

// MARK: - Doing the scrolling

extension Notification.Name {
    /// Move the page in `userInfo["tab"]` by `userInfo["step"]`. Only
    /// `RootView` holds the pool, as with reload and the navigation verbs.
    static let zenScrollPage = Notification.Name("zen.scrollPage")
}

enum PageScrollCommand {
    static func post(_ step: PageScrollStep, tabID: UUID?) {
        var info: [String: String] = ["step": step.rawValue]
        if let tabID { info["tab"] = tabID.uuidString }
        NotificationCenter.default.post(name: .zenScrollPage, object: nil, userInfo: info)
    }
}

/// Feeds the helper its settings, watches the page-scroll notifications, and
/// performs the scroll. A modifier for the same reason `CompactBarBridge` is
/// one: `RootView`'s own chain is already at the type checker's limit.
struct NavigationHelperBridge: ViewModifier {
    @ObservedObject var state: BrowserState
    @ObservedObject var helper: NavigationHelperController
    let pool: WebViewPool

    func body(content: Content) -> some View {
        content
            .onAppear(perform: sync)
            .onChange(of: state.display.navigationHelperEnabled) { _, _ in sync() }
            .onChange(of: state.settings.compactHideDelay) { _, _ in sync() }
            .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollBegan)) { _ in
                helper.pageDidScroll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollEnded)) { _ in
                helper.scrollDidEnd()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenScrollPage)) { note in
                scroll(note)
            }
            .onChange(of: isCovered) { _, covered in helper.coveredDidChange(covered) }
    }

    /// The page is not what you are looking at right now — the same list
    /// `CompactBarBridge` uses, for the same reason.
    private var isCovered: Bool {
        state.isOmniboxOpen || state.isSettingsPresented || state.isHistorySheetPresented
            || state.isSidebarVisible || state.focusLocked
    }

    private func sync() {
        helper.stillDelay = state.settings.compactHideDelay
        helper.isEnabled = state.display.navigationHelperEnabled
    }

    private func scroll(_ note: Notification) {
        guard let raw = note.userInfo?["step"] as? String,
            let step = PageScrollStep(rawValue: raw)
        else { return }
        let tabID =
            (note.userInfo?["tab"] as? String).flatMap(UUID.init(uuidString:))
            ?? state.activeTabID
        guard let tabID, let view = pool.existing(for: tabID) else { return }
        let scrollView = view.scrollView
        let target = PageScroll.target(
            step, from: scrollView.contentOffset.y,
            viewportHeight: scrollView.bounds.height,
            contentHeight: scrollView.contentSize.height,
            topInset: scrollView.contentInset.top,
            bottomInset: scrollView.contentInset.bottom)
        guard abs(target - scrollView.contentOffset.y) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: true)
    }
}
