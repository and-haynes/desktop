// A thumb-sized action panel. Page tools stay together, layout choices are
// visible, and Settings never scrolls out of reach. Actions that present another
// sheet are handed back to RootView after this one has finished dismissing.

import SwiftUI

struct BrowserMenuRequest: Identifiable {
    let id = UUID()
    let tabID: UUID?
}

struct BrowserMenuSheet: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var zoom: PageZoomStore
    @ObservedObject var extensions: ExtensionHost
    let tabID: UUID?
    let context: BarActionContext
    let onChoose: (@escaping () -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isLeaving = false
    @State private var showsExtensions = false

    private var tab: Tab? { state.tab(id: tabID) }
    private var pageURL: URL? { tab.flatMap { $0.isNewTabPage ? nil : $0.url } }
    private var currentZoom: Double { zoom.zoom(for: pageURL, default: state.display.textSize) }
    private var layout: BarLayout { state.display.barLayout }
    private var navigation: TabNavigationState { state.navigation(for: tabID) }
    private var surface: Color { palette.text.withAlpha(0.065).color }
    private var pinsLocal: Bool {
        !dynamicTypeSize.isAccessibilitySize
            && layout.overflowSlots.contains(where: { $0.action == .localServices })
    }
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: dynamicTypeSize >= .xxxLarge ? 2 : 3)
    }
    private var actions: [BarSlotItem] {
        layout.overflowSlots.filter {
            $0.action != .settings && $0.action != .layoutCycle
                && !(pinsLocal && $0.action == .localServices)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    readingTools
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(actions) { item in actionButton(item.action) }
                    }
                    if layout.overflowSlots.contains(where: { $0.action == .layoutCycle }) {
                        layoutChoices
                    }
                    if ExtensionHost.isSupported && extensions.hasAnythingInstalled {
                        extensionActions
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("browserMenuScroll")
            Divider().padding(.horizontal, 20)
            destinations
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .foregroundStyle(palette.text.color)
        .tint(palette.accent.color)
        .presentationBackground(palette.brandingBG.color)
        .presentationCornerRadius(30)
        .presentationDragIndicator(.visible)
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(640), .large]
        )
        .allowsHitTesting(!isLeaving)
        .onAppear {
            if layout.haptics { Haptics.shared.prepare(.menuSelection) }
        }
    }

    private var destinations: some View {
        HStack(spacing: 8) {
            if pinsLocal {
                Button {
                    choose(.localServices)
                } label: {
                    Label("Local", systemImage: BarAction.localServices.symbol)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(ZenPressStyle(pressedScale: 0.98))
                .accessibilityIdentifier("menuAction-localServices")
                Divider().frame(height: 24)
            }
            Button {
                choose(.settings)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                    Text("Settings").fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle(pressedScale: 0.98))
            .accessibilityIdentifier("menuSettings")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Page menu").font(.headline).accessibilityAddTraits(.isHeader)
                Text(pageURL?.host ?? "Zen")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(surface, in: Circle())
            }
            .buttonStyle(ZenPressStyle())
            .accessibilityLabel("Close menu")
            .accessibilityIdentifier("closeBrowserMenu")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var readingTools: some View {
        let stack =
            dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return stack {
            Button {
                choose {
                    NotificationCenter.default.post(name: .zenToggleReaderView, object: nil)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.plaintext")
                    Text(state.isReaderOpen ? "Hide Reader" : "Reader")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(ZenPressStyle(pressedScale: 0.98))
            .disabled(pageURL == nil)
            .accessibilityLabel(state.isReaderOpen ? "Hide Reader" : "Show Reader")
            .accessibilityIdentifier("menuReader")

            HStack(spacing: 0) {
                zoomButton(.smaller, symbol: "textformat.size.smaller", title: "Smaller")
                    .disabled(pageURL == nil || PageZoom.isAtMinimum(currentZoom))
                Button {
                    PageZoomCommand.post(.reset, tabID: tabID)
                } label: {
                    Text(PageZoom.percentLabel(currentZoom))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ZenPressStyle())
                .layoutPriority(1)
                .disabled(pageURL == nil || !zoom.hasOverride(for: pageURL))
                .accessibilityLabel("Text size \(PageZoom.percentLabel(currentZoom))")
                .accessibilityHint("Reset to your default text size")
                .accessibilityIdentifier("textSizeReadout")
                zoomButton(.larger, symbol: "textformat.size.larger", title: "Larger")
                    .disabled(pageURL == nil || PageZoom.isAtMaximum(currentZoom))
            }
            .background(surface, in: RoundedRectangle(cornerRadius: 16))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: currentZoom)
        }
    }

    private func zoomButton(_ change: PageZoomChange, symbol: String, title: String) -> some View {
        Button {
            PageZoomCommand.post(change, tabID: tabID)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(change == .smaller ? "textSizeSmaller" : "textSizeLarger")
    }

    private func actionButton(_ action: BarAction) -> some View {
        let enabled = BarActionRunner.isEnabled(action, state: state, tabID: tabID)
        let isOn = BarActionRunner.isOn(action, state: state, tabID: tabID)
        return Button {
            choose(action)
        } label: {
            VStack(spacing: 8) {
                Image(
                    systemName: action.symbol(
                        isLoading: navigation.isLoading,
                        isBookmarked: BarActionRunner.isOn(.bookmark, state: state, tabID: tabID))
                )
                .font(.system(size: 19, weight: .medium))
                Text(title(action))
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 88)
            .foregroundStyle(isOn ? palette.accent.color : palette.text.color)
            .background(
                isOn ? palette.accent.withAlpha(0.16).color : surface,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(palette.accent.color)
                        .padding(7)
                }
            }
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(ZenPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(title(action))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("menuAction-\(action.rawValue)")
    }

    private var layoutChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layout").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            let stack =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
            stack {
                ForEach(BrowserLayout.allCases) { option in
                    Button {
                        choose(afterDismissal: false) { state.setLayout(option) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: option.symbol).font(.body)
                            Text(option.displayName).font(.caption.weight(.medium))
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(
                            state.display.layout == option
                                ? palette.accent.withAlpha(0.16).color : .clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ZenPressStyle())
                    .accessibilityAddTraits(state.display.layout == option ? .isSelected : [])
                    .accessibilityIdentifier("menuLayout-\(option.rawValue)")
                }
            }
            .padding(4)
            .background(surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var extensionActions: some View {
        VStack(spacing: 4) {
            Button {
                feedback()
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                    showsExtensions.toggle()
                }
            } label: {
                HStack {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                    Spacer()
                    let badged = extensions.menuActions.filter { !$0.badgeText.isEmpty }.count
                    if badged > 0 {
                        Text("\(badged)").font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(palette.accent.withAlpha(0.16).color, in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showsExtensions ? 180 : 0))
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle(pressedScale: 0.98))
            .accessibilityValue(showsExtensions ? "Expanded" : "Collapsed")
            if showsExtensions {
                ForEach(extensions.menuActions) { action in
                    Button {
                        choose { extensions.performAction(action.id) }
                    } label: {
                        Text(action.detail)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 16).contentShape(Rectangle())
                    }
                    .buttonStyle(ZenPressStyle(pressedScale: 0.98))
                    .disabled(!action.isEnabled)
                    .accessibilityIdentifier("extensionAction-\(action.id)")
                }
                if extensions.menuActions.isEmpty {
                    Text("No extensions on this page")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func title(_ action: BarAction) -> String {
        switch action {
        case .reloadStop: return navigation.isLoading ? "Stop" : "Reload"
        case .splitView: return state.isSplitActive ? "Exit Split View" : "Split View"
        case .compactToggle:
            return state.display.compactModeEnabled ? "Exit Compact Mode" : "Compact Mode"
        case .focusMode: return state.isFocusMode ? "Leave Focus (erases)" : "Focus Mode"
        case .desktopSite: return state.settings.preferDesktopSite ? "Mobile Site" : "Desktop Site"
        case .bookmark:
            return BarActionRunner.isOn(.bookmark, state: state, tabID: tabID)
                ? "Remove Bookmark" : "Add Bookmark"
        default: return action.title
        }
    }

    private func feedback() {
        if layout.haptics { Haptics.shared.fire(.menuSelection) }
    }

    private func choose(_ action: BarAction) {
        let afterDismissal: Bool
        switch action {
        case .share, .settings, .history, .localServices, .passwords, .extensions,
            .omnibox, .sidebar, .glance:
            afterDismissal = true
        default:
            afterDismissal = false
        }
        choose(afterDismissal: afterDismissal) {
            BarActionRunner.perform(action, state: state, context: context)
        }
    }

    private func choose(afterDismissal: Bool = true, _ action: @escaping () -> Void) {
        guard !isLeaving else { return }
        isLeaving = true
        feedback()
        if afterDismissal {
            onChoose(action)
        } else {
            // A setting or page command should commit with the touch, even if
            // the app backgrounds before the closing animation finishes.
            action()
            onChoose({})
        }
    }
}
