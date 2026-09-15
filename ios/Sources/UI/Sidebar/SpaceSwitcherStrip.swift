//  SpaceSwitcherStrip.swift
//  `#zen-sidebar-foot-buttons` — the strip along the bottom of the sidebar.
//  Expanded it is a row with `gap: 5px` and `justify-content: space-between`;
//  it holds the space switcher plus the footer actions.

import SwiftUI

struct SpaceSwitcherStrip: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @Binding var editingSpace: Space?
    @Binding var isCreatingSpace: Bool

    var body: some View {
        VStack(spacing: 8) {
            Divider().overlay(palette.border.color)

            HStack(spacing: ZenMetrics.footerGap) {
                spaceChips
                Spacer(minLength: 4)
                footerButton("clock.arrow.circlepath", "History") {
                    state.isHistorySheetPresented = true
                }
                footerButton("gearshape", "Settings") {
                    state.isSettingsPresented = true
                }
            }
        }
        .padding(.horizontal, ZenMetrics.sidebarPadding)
        .padding(.bottom, 4)
    }

    private var spaceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZenMetrics.footerGap) {
                ForEach(state.spaces) { space in
                    spaceChip(space)
                }
                Button {
                    isCreatingSpace = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text.withAlpha(0.6).color)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(ZenPressStyle())
                .accessibilityLabel("New Space")
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func spaceChip(_ space: Space) -> some View {
        let isActive = space.id == state.activeSpaceID
        // Each chip previews its own space's accent, so the strip reads as a
        // row of themes rather than a row of grey icons.
        let chipAccent = space.accent(isDark: palette.isDark)
        return Button {
            guard !isActive else { return }
            Haptics.shared.fire(.spaceSwitchTick)
            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                state.switchSpace(to: space.id)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(240))
                Haptics.shared.fire(.spaceSettle)
            }
        } label: {
            SpaceIconView(space: space, size: isActive ? 15 : 13)
                .foregroundStyle(isActive ? palette.text.color : palette.text.withAlpha(0.5).color)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? chipAccent.withAlpha(0.35).color : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isActive ? chipAccent.withAlpha(0.6).color : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            Button { editingSpace = space } label: { Label("Edit Space", systemImage: "paintpalette") }
            if state.spaces.count > 1 {
                Button(role: .destructive) {
                    withAnimation { state.removeSpace(space.id) }
                } label: { Label("Delete Space", systemImage: "trash") }
            }
        }
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text.withAlpha(0.65).color)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(label)
    }
}

/// The active space's name and icon, shown above the tab list —
/// `--zen-workspace-indicator-height: 44px`.
struct SpaceIndicator: View {
    let space: Space
    @Environment(\.zenPalette) private var palette
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                SpaceIconView(space: space, size: 15)
                Text(space.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.4)
            }
            .foregroundStyle(palette.text.color)
            .padding(.horizontal, ZenMetrics.rowInlinePadding)
            .frame(height: ZenTokens.spaceIndicatorHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
    }
}
