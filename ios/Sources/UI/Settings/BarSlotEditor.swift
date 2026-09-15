//  BarSlotEditor.swift
//  Arranging the bar's buttons (#00896, #008AC).
//
//  The first cut was a row of draggable chips per slot with Remove hidden in a
//  context menu. Andy could not work out how to take the Bookmark button off
//  the bar, and he was right not to: a horizontally scrolling row of chips has
//  no affordance that says "this can be taken away", and press-and-hold is not
//  an affordance at all — it is something you already have to know about. An
//  editor whose main verb is invisible is not an editor.
//
//  So the slots are rows in a list, and *every* way you would reasonably try to
//  remove a button works:
//
//  * a red minus at the head of each row, always visible, never a hover state;
//  * swipe left, which is what a list row trains you to try;
//  * Remove in the row's context menu, for the person who already knows.
//
//  Removing is not deleting. A button that comes off the bar lands in the
//  **library** below, which lists exactly the actions that are *not* currently
//  placed — so "where did Bookmark go?" has an answer on the same screen, and
//  putting it back is one tap on a `+`. A library that listed everything could
//  not answer that question, which is why `unplacedActions` exists.
//
//  Order has the same belt and braces: drag the grip to reorder inside a slot
//  (`.onMove`, with the list held in edit mode so the grips are always there),
//  drag a row onto another slot to move between them (`.draggable` /
//  `.dropDestination`), or use "Move to…" in the context menu when dragging is
//  awkward — which on a phone, inside a sheet, inside a scroll view, it often
//  is.
//
//  The drag payload is a plain string because that is what survives
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
    /// Undo, surfaced *here* as well as in the toolbar: the toolbar button is
    /// off the top of the screen by the time you are editing buttons, and a
    /// destructive action needs its undo within reach of the thumb that did it.
    var canUndo: Bool = false
    var undo: () -> Void = {}
    /// Back to the preset this layout came from.
    var resetTitle: String = "Reset to Zen"
    var reset: () -> Void = {}

    @Environment(\.zenPalette) private var palette

    /// Set when a drop or an add was refused, so the slot can say why rather
    /// than silently doing nothing.
    @State private var rejected: BarSlot?
    @State private var rejectedAt = Date.distantPast
    @State private var editingLongPress: BarSlotItem?

    var body: some View {
        List {
            hintSection
            ForEach(BarSlot.allCases) { slot in
                slotSection(slot)
            }
            librarySection
            actionsSection
        }
        // Permanent edit mode. This is what puts a reorder grip on every row
        // and a remove control at the head of it *without* asking anyone to
        // find an Edit button first — which was the whole complaint.
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .sheet(item: $editingLongPress) { item in
            BarLongPressPicker(item: item, layout: $layout, willChange: willChange)
                .environment(\.zenPalette, palette)
        }
    }

    // MARK: How this works

    private var hintSection: some View {
        Section {
            Label(
                "Drag to reorder, swipe to remove, tap + to add.",
                systemImage: "hand.draw"
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("barEditorHint")
        }
    }

    // MARK: Slots

    @ViewBuilder
    private func slotSection(_ slot: BarSlot) -> some View {
        let items = layout.slots(slot)
        Section {
            if items.isEmpty {
                Text("Nothing here yet — add something from the library below.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .deleteDisabled(true)
                    .moveDisabled(true)
            }
            ForEach(items) { item in
                slotRow(item: item, slot: slot)
            }
            .onDelete { offsets in
                // Swipe to remove. The same verb as the minus and the context
                // menu — three doors, one room.
                willChange()
                let doomed = offsets.compactMap { index -> UUID? in
                    let current = layout.slots(slot)
                    return index < current.count ? current[index].id : nil
                }
                for id in doomed { layout.remove(id) }
                Haptics.shared.fire(.tabClose)
            }
            .onMove { offsets, destination in
                willChange()
                move(in: slot, from: offsets, to: destination)
            }
        } header: {
            HStack {
                Text(slot.title)
                Spacer()
                Text(slot.countLabel(items.count))
                    .monospacedDigit()
                    .foregroundStyle(
                        layout.canAdd(to: slot)
                            ? Color.secondary : Color(ZenTokens.warningColor.uiColor))
                    .accessibilityIdentifier("barSlotCount-\(slot.rawValue)")
            }
        } footer: {
            if isRejecting(slot) {
                Text("\(slot.title) is full — \(slot.capacity) is the most it holds.")
                    .foregroundStyle(ZenTokens.warningColor.color)
            }
        }
        // Dropping anywhere in the section appends to it, which is what a drag
        // that lands in the gap between rows means.
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, into: slot, at: layout.slots(slot).count)
        }
    }

    private func slotRow(item: BarSlotItem, slot: BarSlot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.action.symbol)
                .font(.system(size: 15))
                .foregroundStyle(palette.accent.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.action.title)
                if let longPress = item.longPress {
                    Text("Hold: \(longPress.title)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .draggable(BarDragPayload.item(item.id)) {
            Label(item.action.title, systemImage: item.action.symbol).padding(8)
        }
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, into: slot, at: index(of: item.id, in: slot))
        }
        // Swipe left. `allowsFullSwipe` off on purpose: a full swipe that
        // removes a button the moment your thumb passes the edge is too easy
        // to do by accident while scrolling a long list.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                remove(item)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
        .contextMenu {
            Button {
                editingLongPress = item
            } label: {
                Label(
                    item.longPress == nil
                        ? "Add long press…" : "Long press: \(item.longPress?.title ?? "")",
                    systemImage: "hand.tap")
            }
            ForEach(BarSlot.allCases.filter { $0 != slot }) { other in
                Button {
                    willChange()
                    _ = layout.move(item.id, to: other, at: layout.slots(other).count)
                    Haptics.shared.fire(.dragDrop)
                } label: {
                    Label("Move to \(other.placePhrase)", systemImage: "arrow.right")
                }
                .disabled(!layout.canAdd(to: other))
            }
            Divider()
            Button(role: .destructive) { remove(item) } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
        .accessibilityLabel("\(item.action.title) in \(slot.title)")
        .accessibilityIdentifier("barChip-\(item.action.rawValue)")
    }

    // MARK: The library

    @ViewBuilder
    private var librarySection: some View {
        let unplaced = layout.unplacedActions
        Section {
            if unplaced.isEmpty {
                Text("Every action is on the bar somewhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(unplaced) { action in
                libraryRow(action)
            }
        } header: {
            Text("Library")
        } footer: {
            Text(
                "Everything not currently on the bar. Removing a button puts it "
                    + "back here — nothing is ever thrown away.")
        }
    }

    private func libraryRow(_ action: BarAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(action.title)
            Spacer()
            // The menu is the `+`: one tap opens it, one more says where. A
            // bare `+` would have to guess a slot, and guessing wrong on a
            // four-item slot costs an undo.
            Menu {
                ForEach(BarSlot.allCases) { slot in
                    Button {
                        add(action, to: slot)
                    } label: {
                        Label("Add to \(slot.placePhrase)", systemImage: "plus")
                    }
                    .disabled(!layout.canAdd(to: slot))
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(palette.accent.color)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add \(action.title)")
            .accessibilityIdentifier("barAdd-\(action.rawValue)")
        }
        .deleteDisabled(true)
        .moveDisabled(true)
        .draggable(BarDragPayload.library(action)) {
            Label(action.title, systemImage: action.symbol).padding(8)
        }
        .accessibilityIdentifier("barLibrary-\(action.rawValue)")
    }

    // MARK: Undo and reset

    private var actionsSection: some View {
        Section {
            Button {
                undo()
            } label: {
                Label("Undo last change", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            .accessibilityIdentifier("barUndoInline")

            Button {
                reset()
            } label: {
                Label(resetTitle, systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("barResetInline")
        } footer: {
            Text("Undo steps back one change at a time. Reset puts the whole bar back.")
        }
    }

    // MARK: Mutations

    private func index(of id: UUID, in slot: BarSlot) -> Int {
        layout.slots(slot).firstIndex { $0.id == id } ?? layout.slots(slot).count
    }

    private func remove(_ item: BarSlotItem) {
        willChange()
        layout.remove(item.id)
        Haptics.shared.fire(.tabClose)
    }

    private func add(_ action: BarAction, to slot: BarSlot) {
        willChange()
        if layout.add(action, to: slot) {
            Haptics.shared.fire(.dragDrop)
        } else {
            reject(slot)
        }
    }

    /// `.onMove` gives offsets into the slot's own array, so translate to the
    /// model's "put this id at this index" and let `BarLayout` do the work —
    /// reordering inside a slot is allowed even at capacity.
    private func move(in slot: BarSlot, from offsets: IndexSet, to destination: Int) {
        let items = layout.slots(slot)
        guard let source = offsets.first, source < items.count else { return }
        // SwiftUI's destination is the index *before* the removal; the model
        // inserts after it, so a forward move lands one short without this.
        let target = destination > source ? destination - 1 : destination
        _ = layout.move(items[source].id, to: slot, at: target)
        Haptics.shared.fire(.dragDrop)
    }

    private func drop(_ payloads: [String], into slot: BarSlot, at index: Int) -> Bool {
        guard let raw = payloads.first, let payload = BarDragPayload(raw) else { return false }
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

    /// Say no visibly. A refusal that silently does nothing reads as the drag
    /// having missed, and you try again in the same place.
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
