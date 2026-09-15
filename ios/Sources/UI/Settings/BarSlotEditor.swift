//  BarSlotEditor.swift
//  Arranging the bar's buttons by dragging them.
//
//  Two halves that speak the same language: the *slots* (left, right, overflow)
//  and the *library* of actions. A library chip can be dragged into a slot, a
//  slot chip can be dragged to another slot or reordered inside its own, and
//  everything draggable is also tappable — a drag-only interface is unusable
//  with VoiceOver and awkward with one thumb.
//
//  The payload is a plain string because that is what survives SwiftUI's
//  `draggable`/`dropDestination` without a custom `Transferable` per case:
//  `action:<raw>` means "a new button of this kind", `item:<uuid>` means "the
//  one already in a slot". Anything else is ignored.

import SwiftUI
import UniformTypeIdentifiers

enum BarDragPayload {
    static func library(_ action: BarAction) -> String { "action:\(action.rawValue)" }
    static func item(_ id: UUID) -> String { "item:\(id.uuidString)" }

    case newAction(BarAction)
    case existing(UUID)

    init?(_ raw: String) {
        if raw.hasPrefix("action:"), let action = BarAction(rawValue: String(raw.dropFirst(7))) {
            self = .newAction(action)
        } else if raw.hasPrefix("item:"), let id = UUID(uuidString: String(raw.dropFirst(5))) {
            self = .existing(id)
        } else {
            return nil
        }
    }
}

struct BarSlotEditor: View {
    @Binding var layout: BarLayout
    /// Called before any change, so the editor can push an undo snapshot.
    var willChange: () -> Void = {}
    @Environment(\.zenPalette) private var palette

    /// Set when a drop was refused, so the slot can say why rather than
    /// silently doing nothing.
    @State private var rejected: BarSlot?
    @State private var rejectedAt = Date.distantPast
    @State private var editingLongPress: BarSlotItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(BarSlot.allCases) { slot in
                slotSection(slot)
            }
            library
        }
        .sheet(item: $editingLongPress) { item in
            BarLongPressPicker(item: item, layout: $layout, willChange: willChange)
                .environment(\.zenPalette, palette)
        }
    }

    // MARK: Slots

    private func slotSection(_ slot: BarSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slot.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(layout.slots(slot).count)/\(slot.capacity)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(
                        layout.canAdd(to: slot) ? .secondary : Color(ZenTokens.warningColor.uiColor))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(layout.slots(slot).enumerated()), id: \.element.id) {
                        index, item in
                        chip(item: item, slot: slot, index: index)
                    }
                    if layout.slots(slot).isEmpty {
                        Text("Drag an action here")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                    }
                    // A tail target, so dropping past the last chip appends
                    // rather than doing nothing.
                    Color.clear.frame(width: 44, height: 38)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: slot, at: layout.slots(slot).count)
                        }
                }
                .padding(.horizontal, 2)
            }
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.toolbarElementHoverBG.color)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isRejecting(slot) ? ZenTokens.warningColor.color : palette.border.color,
                        lineWidth: isRejecting(slot) ? 1.5 : 0.5)
            }
            .dropDestination(for: String.self) { items, _ in
                drop(items, into: slot, at: layout.slots(slot).count)
            }
            .animation(.easeOut(duration: 0.2), value: isRejecting(slot))
            .accessibilityIdentifier("barSlotRow-\(slot.rawValue)")

            if isRejecting(slot) {
                Text("\(slot.title) is full — \(slot.capacity) is the most it holds.")
                    .font(.system(size: 12))
                    .foregroundStyle(ZenTokens.warningColor.color)
                    .transition(.opacity)
            }
        }
    }

    private func chip(item: BarSlotItem, slot: BarSlot, index: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.action.symbol)
                .font(.system(size: 13, weight: .medium))
            Text(item.action.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if item.longPress != nil {
                // A dot, not a second glyph: the secondary action is a
                // *property* of this button, not another button.
                Circle()
                    .fill(palette.accent.color)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            Capsule().fill(palette.urlbarBackground.color)
        }
        .overlay { Capsule().strokeBorder(palette.borderContrast.color, lineWidth: 0.5) }
        .contentShape(Capsule())
        .draggable(BarDragPayload.item(item.id)) {
            Label(item.action.title, systemImage: item.action.symbol)
                .padding(8)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: slot, at: index)
        }
        .contextMenu {
            Button {
                editingLongPress = item
            } label: {
                Label(
                    item.longPress == nil ? "Add long press…" : "Long press: \(item.longPress?.title ?? "")",
                    systemImage: "hand.tap")
            }
            ForEach(BarSlot.allCases.filter { $0 != slot }) { other in
                Button {
                    willChange()
                    _ = layout.move(item.id, to: other, at: layout.slots(other).count)
                } label: {
                    Label("Move to \(other.title)", systemImage: "arrow.right")
                }
                .disabled(!layout.canAdd(to: other))
            }
            Divider()
            Button(role: .destructive) {
                willChange()
                layout.remove(item.id)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
        .accessibilityLabel("\(item.action.title) in \(slot.title)")
        .accessibilityIdentifier("barChip-\(item.action.rawValue)")
    }

    // MARK: The library

    private var library: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library")
                .font(.system(size: 13, weight: .semibold))
            Text("Drag an action into a slot, or tap it to choose where it goes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(BarActionGroup.allCases.filter { $0 != .other }) { group in
                let actions = BarAction.slotLibrary.filter { $0.group == group }
                if !actions.isEmpty {
                    Text(group.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    FlowingChips(actions: actions) { action in
                        libraryChip(action)
                    }
                }
            }
        }
    }

    private func libraryChip(_ action: BarAction) -> some View {
        Menu {
            ForEach(BarSlot.allCases) { slot in
                Button {
                    willChange()
                    if !layout.add(action, to: slot) { reject(slot) }
                } label: {
                    Label("Add to \(slot.title)", systemImage: slot == .overflow ? "ellipsis" : "plus")
                }
                .disabled(!layout.canAdd(to: slot))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(action.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background { Capsule().fill(palette.toolbarElementHoverBG.color) }
            .overlay { Capsule().strokeBorder(palette.border.color, lineWidth: 0.5) }
            .foregroundStyle(palette.text.color)
        }
        .draggable(BarDragPayload.library(action)) {
            Label(action.title, systemImage: action.symbol).padding(8)
        }
        .accessibilityIdentifier("barLibrary-\(action.rawValue)")
    }

    // MARK: Drops

    private func drop(_ items: [String], into slot: BarSlot, at index: Int) -> Bool {
        guard let raw = items.first, let payload = BarDragPayload(raw) else { return false }
        willChange()
        switch payload {
        case .newAction(let action):
            guard layout.insert(BarSlotItem(action), into: slot, at: index) else {
                reject(slot)
                return false
            }
        case .existing(let id):
            guard layout.move(id, to: slot, at: index) else {
                reject(slot)
                return false
            }
        }
        Haptics.shared.fire(.dragDrop)
        return true
    }

    /// Say no visibly. A drop that silently fails reads as the drag having
    /// missed, and you try again in the same place.
    private func reject(_ slot: BarSlot) {
        Haptics.shared.fire(.loadError)
        withAnimation(.easeOut(duration: 0.2)) {
            rejected = slot
            rejectedAt = Date()
        }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard Date().timeIntervalSince(rejectedAt) >= 2.3 else { return }
            withAnimation(.easeOut(duration: 0.25)) { rejected = nil }
        }
    }

    private func isRejecting(_ slot: BarSlot) -> Bool { rejected == slot }
}

/// A wrapping row of chips. `LazyVGrid` cannot size columns to their content,
/// and a horizontal `ScrollView` hides half the library — so the widths are
/// measured and wrapped by hand.
private struct FlowingChips<Chip: View>: View {
    let actions: [BarAction]
    @ViewBuilder let chip: (BarAction) -> Chip

    var body: some View {
        // Four chips per row is what fits at the default text size on a 6.1in
        // phone; two keeps the longest titles ("Request Desktop Site") legible
        // at the accessibility sizes.
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                chip(action)
            }
        }
    }
}

/// Picking the secondary action for a button.
struct BarLongPressPicker: View {
    let item: BarSlotItem
    @Binding var layout: BarLayout
    var willChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        willChange()
                        layout.setLongPress(nil, for: item.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label("Nothing", systemImage: "circle.dashed")
                            Spacer()
                            if item.longPress == nil {
                                Image(systemName: "checkmark").foregroundStyle(palette.accent.color)
                            }
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text(
                        "Held down rather than tapped. The tap still does "
                            + "\(item.action.title).")
                }

                ForEach(BarActionGroup.allCases) { group in
                    let actions = BarAction.gestureLibrary.filter {
                        $0.group == group && $0 != .none
                    }
                    if !actions.isEmpty {
                        Section(group.title) {
                            ForEach(actions) { action in
                                Button {
                                    willChange()
                                    layout.setLongPress(action, for: item.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Label(action.title, systemImage: action.symbol)
                                        Spacer()
                                        if item.longPress == action {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(palette.accent.color)
                                        }
                                    }
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Long press")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.accent.color)
    }
}
