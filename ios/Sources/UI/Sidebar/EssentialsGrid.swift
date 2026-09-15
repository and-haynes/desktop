//  EssentialsGrid.swift
//  The grid of pinned "essential" tabs at the top of the sidebar.
//
//  `.zen-essentials-container` is a CSS grid with `gap: 4px` and
//  `repeat(auto-fit, minmax(max(23.7%, …), 1fr))` — four across. Tiles are
//  46px tall with a 14px radius, show the favicon only (label and close button
//  are `display: none`), and are shared across every space.

import SwiftUI
import UniformTypeIdentifiers

struct EssentialsGrid: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @State private var draggingID: UUID?

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ZenMetrics.essentialsGap),
            count: ZenMetrics.essentialsColumns)
    }

    var body: some View {
        let essentials = state.essentials
        if essentials.isEmpty {
            emptyHint
        } else {
            LazyVGrid(columns: columns, spacing: ZenMetrics.essentialsGap) {
                ForEach(essentials) { tab in
                    EssentialTile(tab: tab, isActive: tab.id == state.activeTabID, state: state)
                        .onDrag {
                            draggingID = tab.id
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: EssentialDropDelegate(
                                target: tab, state: state, draggingID: $draggingID))
                }
            }
        }
    }

    /// An empty grid would just be a gap; say what the row is for instead.
    private var emptyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "star")
            Text("Long-press a tab to add an Essential")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.text.withAlpha(0.45).color)
        .frame(maxWidth: .infinity)
        .frame(height: ZenMetrics.essentialTileHeight)
        .background {
            RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                .strokeBorder(
                    palette.border.color, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

struct EssentialTile: View {
    let tab: Tab
    let isActive: Bool
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button {
            state.select(tab.id)
            if UIDevice.current.userInterfaceIdiom == .phone { state.isSidebarVisible = false }
        } label: {
            ZStack {
                // `zen.theme.essentials-favicon-bg` — a blurred favicon glow
                // behind the selected tile.
                if isActive, let data = tab.faviconData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 14)
                        .opacity(0.55)
                }
                FaviconView(tab: tab, size: 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ZenMetrics.essentialTileHeight)
            .background {
                RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                    .fill(background)
            }
            .clipShape(RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                    .strokeBorder(
                        isActive ? palette.borderContrast.color : .clear, lineWidth: 0.5)
            }
        }
        .buttonStyle(ZenPressStyle(pressedScale: ZenTokens.activeTabScale))
        .contextMenu { TabContextMenu(tab: tab, state: state) }
        .accessibilityLabel(tab.displayTitle)
    }

    /// Selected: `rgba(255,255,255,.85)` light / `rgba(255,255,255,.2)` dark.
    /// Unselected tiles are transparent until hover — we give them a faint
    /// wash so the grid reads as a grid on a touch screen.
    private var background: Color {
        if isActive {
            return palette.isDark ? Color.white.opacity(0.20) : Color.white.opacity(0.85)
        }
        return palette.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
}

/// Drag-to-reorder within the essentials grid.
struct EssentialDropDelegate: DropDelegate {
    let target: Tab
    let state: BrowserState
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target.id else { return }
        let essentials = state.essentials
        guard let destination = essentials.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            state.moveTab(draggingID, toOffset: destination, kind: .essential, spaceID: nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
