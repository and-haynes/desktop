//  BarActionRunner.swift
//  The one place a `BarAction` turns into something happening.
//
//  A button in a slot, a long press on that button, and a swipe across the bar
//  all arrive here, so the three cannot drift apart: reassigning a swipe to
//  "reload" gets literally the same reload the button does.
//
//  Anything that needs the web view pool goes out as a notification, because
//  the pool lives on RootView and the bar does not — which is the same seam
//  `.zenReloadActiveTab` already used.

import SwiftUI

/// The bits of the surrounding view a bar action cannot reach on its own.
struct BarActionContext {
    /// Which tab the bar is bound to. `nil` means whatever is active.
    var tabID: UUID?
    /// Present the share sheet, which only the owning view can do.
    var share: (URL) -> Void = { _ in }
    /// Put the bar away — the `hideBar` action, which is auto-hide's manual
    /// equivalent and belongs to the view that owns the animation.
    var hideBar: () -> Void = {}
    /// Show the browser action panel.
    var showActionMenu: () -> Void = {}
    /// A menu can confirm the touch before dismissing, then run the action
    /// without a second, delayed tap from the same control.
    var hapticFeedback = true
}

@MainActor
enum BarActionRunner {

    /// Whether the action can do anything right now. A control that would be
    /// inert is drawn dimmed rather than removed, so the bar does not reflow
    /// under your thumb.
    static func isEnabled(_ action: BarAction, state: BrowserState, tabID: UUID?) -> Bool {
        let tab = tabID.flatMap { state.tab(id: $0) } ?? state.activeTab
        let navigation = state.navigation(for: tab?.id)
        switch action {
        case .none: return false
        case .back: return navigation.canGoBack
        case .forward: return navigation.canGoForward
        case .reloadStop, .share, .copyURL, .findInPage, .scrollToTop:
            return tab != nil && !(tab?.isNewTabPage ?? true)
        case .bookmark: return tab != nil && !(tab?.isNewTabPage ?? true)
        case .glance: return tab != nil && !(tab?.isNewTabPage ?? true)
        case .closeTab: return tab != nil
        case .nextTab, .previousTab: return state.tabs.count > 1
        case .spaceSwitcher: return state.spaces.count > 0
        case .eraseFocus: return state.isFocusMode
        case .closeOmnibox: return state.isOmniboxOpen
        default: return true
        }
    }

    /// Whether the action is currently "on", for the controls that latch.
    static func isOn(_ action: BarAction, state: BrowserState, tabID: UUID?) -> Bool {
        let tab = tabID.flatMap { state.tab(id: $0) } ?? state.activeTab
        switch action {
        case .bookmark: return tab.map { state.bookmarks.isBookmarked($0.url) } ?? false
        case .splitView: return state.isSplitActive
        case .compactToggle: return state.display.compactModeEnabled
        case .focusMode: return state.isFocusMode
        case .desktopSite: return state.settings.preferDesktopSite
        case .sidebar: return state.isSidebarVisible
        default: return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func perform(_ action: BarAction, state: BrowserState, context: BarActionContext) {
        let tabID = context.tabID ?? state.activeTabID
        let tab = state.tab(id: tabID)
        let fire: (HapticEvent, BrowserState) -> Void = { event, state in
            guard context.hapticFeedback, state.display.barLayout.haptics else { return }
            Haptics.shared.fire(event)
        }

        switch action {
        case .none:
            return

        case .back:
            post(.zenNavigateBack, tabID)
        case .forward:
            post(.zenNavigateForward, tabID)
        case .reloadStop:
            if state.navigation(for: tabID).isLoading {
                post(.zenStopLoading, tabID)
            } else {
                post(.zenReloadActiveTab, tabID)
            }
        case .scrollToTop:
            post(.zenScrollToTop, tabID)

        case .share:
            if let url = tab?.url, !(tab?.isNewTabPage ?? true) { context.share(url) }
        case .bookmark:
            guard let tab, !tab.isNewTabPage else { return }
            let saved = state.bookmarks.isBookmarked(tab.url)
            fire(saved ? .bookmarkRemove : .bookmarkAdd, state)
            state.bookmarks.toggle(
                url: tab.url, title: tab.displayTitle, spaceID: state.activeSpaceID)
        case .copyURL:
            guard let tab, !tab.isNewTabPage else { return }
            UIPasteboard.general.url = tab.url
        case .findInPage:
            state.isFindBarVisible = true
        case .passwords:
            // The panel decides for itself whether there is a vault and whether
            // anything matches; opening it with nothing to show is still the
            // right answer, because that is where the setup link lives.
            state.isPasswordsPanelPresented = true
        case .extensions:
            // As a *slot* this is a menu and never reaches here — see
            // `OmniboxPill.slotButton`. Everything else (a gesture, the More
            // menu, a keyboard — none of which can anchor a popover) gets the
            // sheet, which is the same list.
            state.isExtensionsPanelPresented = true
        case .desktopSite:
            state.settings.preferDesktopSite.toggle()
        case .popOutVideo:
            // Only RootView can reach the pool, as with reload and the
            // navigation verbs.
            post(.zenPopOutVideo, tabID)

        case .sidebar:
            fire(.sidebarSnap, state)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                state.isSidebarVisible.toggle()
            }
        case .newTab:
            fire(.tabOpen, state)
            state.newTab()
            state.isOmniboxOpen = true
        case .closeTab:
            guard let tabID else { return }
            fire(.tabClose, state)
            state.closeTab(tabID)
        case .nextTab:
            fire(.tabSelect, state)
            state.cycleTab(by: 1)
        case .previousTab:
            fire(.tabSelect, state)
            state.cycleTab(by: -1)
        case .spaceSwitcher:
            // Presented as a menu when it is a button; a *gesture* has nowhere
            // to anchor a popover, so it advances the carousel instead.
            fire(.spaceSwitchTick, state)
            withAnimation { state.cycleSpace(by: 1) }

        case .splitView:
            fire(state.isSplitActive ? .splitExit : .splitEnter, state)
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { state.toggleSplit() }
        case .glance:
            guard let tab, !tab.isNewTabPage else { return }
            fire(.glanceOpen, state)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                state.openGlance(url: tab.url)
            }
        case .layoutCycle:
            NotificationCenter.default.post(name: .zenCycleLayout, object: nil)
        case .compactToggle:
            let on = state.display.compactModeEnabled
            fire(on ? .compactBarShow : .compactBarHide, state)
            // Written at whichever level currently decides it, so toggling it
            // in a space that overrides compact mode changes *that* space.
            state.setCompactMode(!on)
        case .focusMode:
            NotificationCenter.default.post(name: .zenToggleFocusMode, object: nil)
        case .eraseFocus:
            guard state.isFocusMode else { return }
            fire(.tabClose, state)
            withAnimation(.easeOut(duration: 0.2)) { state.eraseFocus() }

        case .history:
            state.isHistorySheetPresented = true
        case .localServices:
            state.isLocalServicesPresented = true
        case .settings:
            state.isSettingsPresented = true

        case .overflowMenu:
            context.showActionMenu()
        case .omnibox:
            fire(.omniboxOpen, state)
            state.openOmnibox(
                for: context.tabID, prefill: tab.map(OmniboxPill.editableText) ?? "")
        case .closeOmnibox:
            guard state.isOmniboxOpen else { return }
            fire(.omniboxClose, state)
            state.isOmniboxOpen = false
        case .hideBar:
            context.hideBar()
        case .actionMenu:
            context.showActionMenu()
        }
    }

    private static func post(_ name: Notification.Name, _ tabID: UUID?) {
        NotificationCenter.default.post(
            name: name, object: nil,
            userInfo: tabID.map { ["tab": $0.uuidString] })
    }
}

extension Notification.Name {
    /// The three pool-owned navigation verbs the bar can now carry. `userInfo`
    /// optionally names a tab; without one they act on the active tab, which is
    /// what `.zenReloadActiveTab` has always done.
    static let zenNavigateBack = Notification.Name("zen.navigateBack")
    static let zenNavigateForward = Notification.Name("zen.navigateForward")
    static let zenStopLoading = Notification.Name("zen.stopLoading")
    static let zenScrollToTop = Notification.Name("zen.scrollToTop")
}
