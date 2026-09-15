//  ZenSpacesRecords.swift
//  Zen desktop's `spaces` collection, as records this app can read and write.
//
//  The schema is not ours; it is whatever `ZenSpacesSyncModel.projections()`
//  emits, and a field we get wrong is a field the desktop will overwrite on
//  every sync. Each record's cleartext is
//
//      { "id": <record id>, "kind": <kind>, "data": { … } }
//
//  with six kinds. We project three of them — `space`, `tab` and the single
//  `layout` record — and *hold* the other three (`container`, `folder`,
//  `split`) untouched, because a phone has no containers, no tab folders and
//  no four-pane split tree, and deleting what we cannot display would be
//  vandalism rather than sync.
//
//  Two identifier details decide whether the desktop sees our records as the
//  same objects or as duplicates:
//
//  · a space's `uuid` is `Services.uuid.generateUUID().toString()`, which on
//    Gecko keeps its **braces**: `{5f8c…}`;
//  · a tab's id is `` `${Date.now()}-${Math.round(Math.random() * 100)}` `` —
//    not a UUID at all.
//
//  Both are handled in `SyncIdentityMap`.

import CoreGraphics
import Foundation

enum ZenSpacesRecordKind: String, Sendable {
    case container
    case space
    case tab
    case folder
    case split
    case layout

    /// The kinds we materialise. Everything else is held: present on the
    /// server, absent from our projection, and never a deletion.
    var isModelled: Bool {
        self == .space || self == .tab || self == .layout
    }
}

enum ZenSpacesRecords {

    /// `LAYOUT_RECORD_ID` upstream.
    static let layoutRecordID = "layout"

    /// The desktop keys the essentials map by container guid; with no
    /// container it uses this.
    static let defaultEssentialsKey = "default"

    // MARK: - Projection

    /// Everything this device would publish, keyed by record id.
    ///
    /// `retained` is the last payload we saw for each id; fields we do not
    /// model are copied out of it so a desktop-authored record survives a trip
    /// through the phone unchanged.
    static func project(
        spaces: [Space], tabs: [Tab], identities: inout SyncIdentityMap,
        retained: [String: JSONValue], symbolShadow: inout [String: String],
        syncNormalTabs: Bool
    ) -> [String: JSONValue] {
        var records: [String: JSONValue] = [:]

        func spaceID(_ space: Space) -> String {
            identities.remoteID(forLocal: space.id) {
                SyncIdentityMap.desktopSpaceID(for: space.id)
            }
        }
        func tabID(_ tab: Tab) -> String {
            identities.remoteID(forLocal: tab.id) { SyncIdentityMap.newDesktopTabID() }
        }

        let syncable = tabs.filter { isSyncable($0, syncNormalTabs: syncNormalTabs) }

        // Spaces, with their pinned (and optionally normal) children in strip
        // order — `#childSequence` upstream.
        for space in spaces {
            let id = spaceID(space)
            let children =
                syncable
                .filter { $0.kind != .essential && $0.spaceID == space.id }
                .map(tabID)
            records[id] = record(
                id: id, kind: .space,
                data: spaceData(
                    space, id: id, children: children,
                    retained: retained[id]?["data"], symbolShadow: &symbolShadow))
        }

        for tab in syncable {
            let id = tabID(tab)
            let workspace = tab.kind.isGlobal ? nil : tab.spaceID.flatMap {
                local in spaces.first { $0.id == local }.map(spaceID)
            }
            records[id] = record(
                id: id, kind: .tab,
                data: tabData(
                    tab, id: id, workspaceUUID: workspace, retained: retained[id]?["data"]))
        }

        // The layout record carries the space order and the essentials order —
        // neither belongs to any one space.
        if !spaces.isEmpty {
            let essentials = syncable.filter { $0.kind.isGlobal }.map(tabID)
            records[layoutRecordID] = record(
                id: layoutRecordID, kind: .layout,
                data: .object([
                    "spaces": .array(spaces.map { .string(spaceID($0)) }),
                    "essentials": .object([
                        defaultEssentialsKey: .array(essentials.map { .string($0) })
                    ]),
                ]))
        }

        return records
    }

    /// Upstream's `#isSyncableTab`: pinned or essential always, ordinary tabs
    /// only when the owner asked for them. An empty tab is never syncable —
    /// `zen://newtab` means nothing on a desktop.
    static func isSyncable(_ tab: Tab, syncNormalTabs: Bool) -> Bool {
        guard !tab.isNewTabPage else { return false }
        guard tab.url.scheme == "http" || tab.url.scheme == "https" else { return false }
        return tab.kind != .normal || syncNormalTabs
    }

    static func record(id: String, kind: ZenSpacesRecordKind, data: JSONValue) -> JSONValue {
        .object([
            "id": .string(id),
            "kind": .string(kind.rawValue),
            "data": data,
        ])
    }

    // MARK: Space payload

    static func spaceData(
        _ space: Space, id: String, children: [String], retained: JSONValue?,
        symbolShadow: inout [String: String]
    ) -> JSONValue {
        var icon: JSONValue = .null
        if space.isSymbol {
            // The desktop's icon field is an emoji (or a chrome:// svg it
            // supplies itself); an SF Symbol name would render as literal
            // text there. Substitute the nearest emoji and remember the
            // symbol, so a round trip through our own device keeps it.
            if let emoji = SpaceIconBridge.emoji(forSymbol: space.icon) {
                icon = .string(emoji)
                symbolShadow[id] = space.icon
            }
        } else if !space.icon.isEmpty {
            icon = .string(space.icon)
            symbolShadow[id] = nil
        }

        return .object([
            "uuid": .string(id),
            "name": .string(space.name),
            "icon": icon,
            "theme": ZenThemeBridge.json(from: space.theme, retained: retained?["theme"]),
            // Firefox containers have no WebKit equivalent; the desktop reads
            // a null guid as "no container", which is the honest answer.
            "containerGuid": retained?["containerGuid"] ?? .null,
            "children": .array(children.map { .string($0) }),
        ])
    }

    // MARK: Tab payload

    static func tabData(
        _ tab: Tab, id: String, workspaceUUID: String?, retained: JSONValue?
    ) -> JSONValue {
        let essential = tab.kind.isGlobal
        // A pinned tab's identity is frozen at pin time upstream, so the
        // record's url is the *pinned* url and not wherever it has navigated.
        let url = tab.kind.resetsOnClose ? (tab.pinnedURL ?? tab.url) : tab.url

        return .object([
            "tabId": .string(id),
            "url": .string(url.absoluteString),
            "title": .string(tab.title),
            // We capture favicons as image data on navigation, and the
            // desktop only accepts data:/chrome:/about:/resource: urls for an
            // icon. Rather than ship a base64 PNG in every record, keep
            // whatever the desktop last told us.
            "icon": retained?["icon"] ?? .string(""),
            "containerGuid": retained?["containerGuid"] ?? .null,
            "essential": .bool(essential),
            "pinned": .bool(tab.kind.resetsOnClose),
            "workspaceUuid": essential ? .null : .string(orNull: workspaceUUID),
            "folderId": retained?["folderId"] ?? .null,
            "staticLabel": retained?["staticLabel"] ?? .null,
            "hasStaticIcon": retained?["hasStaticIcon"] ?? .bool(false),
            "defaultContainer": retained?["defaultContainer"] ?? .bool(false),
        ])
    }

    // MARK: - Parsing

    struct RemoteSpace: Equatable, Sendable {
        var uuid: String
        var name: String
        var icon: String?
        var theme: ZenTheme
        var children: [String]
    }

    struct RemoteTab: Equatable, Sendable {
        var tabID: String
        var url: URL
        var title: String
        var essential: Bool
        var pinned: Bool
        var workspaceUUID: String?
        /// A tab inside a folder or a split is still a tab; we place it in its
        /// space and ignore the grouping we cannot draw.
        var folderID: String?
    }

    struct RemoteLayout: Equatable, Sendable {
        var spaces: [String]
        /// Flattened across containers — we have one.
        var essentials: [String]
    }

    static func remoteSpace(from data: JSONValue, id: String) -> RemoteSpace? {
        let icon = data["icon"]?.stringValue
        return RemoteSpace(
            uuid: data["uuid"]?.stringValue ?? id,
            name: data["name"]?.stringValue ?? "",
            icon: icon,
            theme: ZenThemeBridge.theme(from: data["theme"]),
            children: data["children"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    static func remoteTab(from data: JSONValue, id: String) -> RemoteTab? {
        guard let urlString = data["url"]?.stringValue, let url = URL(string: urlString),
            url.scheme == "http" || url.scheme == "https"
        else { return nil }
        let essential = data["essential"]?.boolValue ?? false
        return RemoteTab(
            tabID: data["tabId"]?.stringValue ?? id,
            url: url,
            title: data["title"]?.stringValue ?? "",
            essential: essential,
            pinned: data["pinned"]?.boolValue ?? essential,
            workspaceUUID: essential ? nil : data["workspaceUuid"]?.stringValue,
            folderID: data["folderId"]?.stringValue)
    }

    static func remoteLayout(from data: JSONValue) -> RemoteLayout {
        var essentials: [String] = []
        // Keys are container guids; sort them so the flattening is stable, and
        // put the default container first because that is where ours live.
        let map = data["essentials"]?.objectValue ?? [:]
        for key in map.keys.sorted(by: { a, _ in a == defaultEssentialsKey }) {
            essentials += map[key]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        return RemoteLayout(
            spaces: data["spaces"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            essentials: essentials)
    }
}

// MARK: - Theme

/// `ZenTheme` ↔ the desktop's `{type:"gradient", gradientColors, opacity, texture}`.
///
/// A gradient dot upstream is
///
///     { c: [r,g,b], isCustom, algorithm, isPrimary, lightness, position: {x,y}, type }
///
/// of which only `c` and `isPrimary` mean anything here. `position` is in
/// pixels inside the desktop picker's 380×380 wheel, using a different
/// convention from ours (saturation as radius, not lightness), so we never
/// translate one into the other: the colour is the shared truth, and the
/// desktop's own `position` is copied back out of the retained record so its
/// dots do not jump when the phone touches the theme.
enum ZenThemeBridge {

    /// `nsZenThemePicker` hard-codes a 380px wheel; its centre and radius are
    /// what `calculateInitialPosition` uses when a colour arrives without one.
    static let wheelSize: Double = 380

    static func json(from theme: ZenTheme, retained: JSONValue?) -> JSONValue {
        guard !theme.isEmpty else { return retained ?? .null }

        let retainedDots = retained?["gradientColors"]?.arrayValue ?? []
        var dots: [JSONValue] = []
        for (index, dot) in theme.dots.enumerated() {
            let previous = index < retainedDots.count ? retainedDots[index] : nil
            dots.append(json(from: dot, harmony: theme.harmony, retained: previous))
        }
        return .object([
            "type": .string("gradient"),
            "gradientColors": .array(dots),
            "opacity": .number(theme.opacity),
            "texture": .number(theme.texture),
        ])
    }

    static func json(from dot: ZenGradientDot, harmony: ZenColorHarmony, retained: JSONValue?)
        -> JSONValue
    {
        let r = Int((dot.color.r * 255).rounded())
        let g = Int((dot.color.g * 255).rounded())
        let b = Int((dot.color.b * 255).rounded())
        let (_, _, lightness) = dot.color.hsl

        var object: [String: JSONValue] = retained?.objectValue ?? [:]
        object["c"] = .array([.number(Double(r)), .number(Double(g)), .number(Double(b))])
        object["isCustom"] = .bool(false)
        object["isPrimary"] = .bool(dot.isPrimary)
        object["algorithm"] = .string(harmony.rawValue)
        object["lightness"] = .number(lightness.rounded())
        if object["type"] == nil { object["type"] = .null }
        if object["position"] == nil {
            object["position"] = desktopPosition(for: dot.color)
        }
        return .object(object)
    }

    /// `calculateInitialPosition([r,g,b])` upstream: the hue becomes an angle
    /// and the saturation a fraction of the radius, on a 380px wheel with no
    /// padding.
    static func desktopPosition(for color: ZenColor) -> JSONValue {
        let (hue, saturation, _) = color.hsl
        let centre = wheelSize / 2
        let radius = wheelSize / 2
        let angle = hue / 360 * 2 * .pi
        return .object([
            "x": .number((centre + radius * (saturation / 100) * cos(angle)).rounded()),
            "y": .number((centre + radius * (saturation / 100) * sin(angle)).rounded()),
        ])
    }

    static func theme(from json: JSONValue?) -> ZenTheme {
        guard let json, let dots = json["gradientColors"]?.arrayValue else { return .default }
        var theme = ZenTheme()
        theme.opacity = json["opacity"]?.doubleValue ?? 0.5
        theme.texture = json["texture"]?.doubleValue ?? 0
        theme.dots = dots.compactMap(dot(from:))
        if let algorithm = dots.first?["algorithm"]?.stringValue,
            let harmony = ZenColorHarmony(rawValue: algorithm)
        {
            theme.harmony = harmony
        }
        theme.normalise()
        return theme
    }

    static func dot(from json: JSONValue) -> ZenGradientDot? {
        guard let color = color(from: json["c"]) else { return nil }
        return ZenGradientDot(
            color: color,
            isPrimary: json["isPrimary"]?.boolValue ?? false,
            // Our editor's positions are lightness-based; recompute rather
            // than reuse the desktop's pixel coordinate, which means
            // something else entirely.
            position: ZenGradientGenerator.position(of: color))
    }

    /// `c` is `[r,g,b]` for a wheel dot, or a CSS colour string when the dot
    /// came from the desktop's custom-colour list.
    static func color(from json: JSONValue?) -> ZenColor? {
        guard let json else { return nil }
        if let components = json.arrayValue?.compactMap(\.doubleValue), components.count >= 3 {
            return ZenColor(
                Int(components[0].rounded()), Int(components[1].rounded()),
                Int(components[2].rounded()),
                components.count > 3 ? components[3] : 1)
        }
        if let text = json.stringValue, case .success(let color) = ColorParsing.parse(text) {
            return color
        }
        return nil
    }
}

// MARK: - Icons

/// SF Symbol ↔ emoji, for the one field where the two browsers cannot mean the
/// same thing. Zen desktop's space icon is an emoji; ours may be an SF Symbol,
/// which would appear on a desktop as the literal string "briefcase.fill".
/// We publish the nearest emoji and remember what it stood for.
enum SpaceIconBridge {

    static let symbolToEmoji: [String: String] = [
        "house.fill": "🏠", "briefcase.fill": "💼", "book.fill": "📚", "cart.fill": "🛒",
        "heart.fill": "❤️", "star.fill": "⭐️", "bolt.fill": "⚡️", "leaf.fill": "🌿",
        "flame.fill": "🔥", "gamecontroller.fill": "🎮", "music.note": "🎵",
        "camera.fill": "📷", "paintbrush.fill": "🎨", "hammer.fill": "🔨",
        "graduationcap.fill": "🎓", "airplane": "✈️", "figure.run": "🏃",
        "brain.head.profile": "🧠", "chart.line.uptrend.xyaxis": "📈", "globe": "🌐",
    ]

    static func emoji(forSymbol symbol: String) -> String? {
        symbolToEmoji[symbol]
    }

    /// The reverse is only consulted for a space we ourselves published, via
    /// the symbol shadow — a desktop-authored 🏠 stays an emoji, because
    /// silently turning someone's emoji into an SF Symbol would be us
    /// deciding what their space looks like.
    static func symbol(forEmoji emoji: String) -> String? {
        symbolToEmoji.first { $0.value == emoji }?.key
    }
}
