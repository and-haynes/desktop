//  TabsEngine.swift
//  The `tabs` collection: one record per device, listing what it has open.
//
//  Unlike every other engine this one is not a merge — each device owns
//  exactly one record, overwrites it wholesale, and only ever reads the
//  others'. That is why other devices' tabs are shown rather than adopted:
//  they are a view of somewhere else, which is what Zen's synced-tabs sidebar
//  section is too.

import Foundation

/// One tab as another device published it.
struct RemoteTabItem: Identifiable, Equatable, Sendable, Codable {
    var title: String
    var url: URL
    var lastUsed: Date
    var icon: URL?

    var id: String { url.absoluteString + "\u{1}" + title }

    var displayTitle: String {
        title.isEmpty ? URLDetector.prettyHost(url) : title
    }
}

/// Another device, and what it has open.
struct RemoteDeviceTabs: Identifiable, Equatable, Sendable, Codable {
    var clientGUID: String
    var clientName: String
    var deviceType: String
    var tabs: [RemoteTabItem]
    var lastModified: Date

    var id: String { clientGUID }

    /// The SF Symbol Zen's synced-tabs section puts beside the device name.
    var symbol: String {
        switch deviceType {
        case "mobile": return "iphone"
        case "tablet": return "ipad"
        default: return "desktopcomputer"
        }
    }
}

enum TabsEngine {
    static let collection = "tabs"

    /// Sync's limits for this collection. Beyond these the server rejects the
    /// record outright, which would look to the owner like sync not working.
    static let maxTabs = 500
    static let maxHistoryEntriesPerTab = 1

    /// Our own record. Pinned and essential tabs are included — on the desktop
    /// they are open tabs too.
    static func outgoing(guid: String, clientName: String, tabs: [Tab], now: Date = Date())
        -> DecryptedRecord
    {
        let items: [JSONValue] = tabs
            .filter { !$0.isNewTabPage && ($0.url.scheme == "http" || $0.url.scheme == "https") }
            .prefix(maxTabs)
            .map { tab in
                .object([
                    "title": .string(tab.displayTitle),
                    // A list, because Firefox sends a few steps of back
                    // history; the current page is the first entry.
                    "urlHistory": .array([.string(tab.url.absoluteString)]),
                    "icon": .string(""),
                    // Seconds, not milliseconds — the desktop divides.
                    "lastUsed": .number(now.timeIntervalSince1970.rounded()),
                ])
            }

        return DecryptedRecord(
            id: guid, modified: 0,
            payload: .object([
                "id": .string(guid),
                "clientName": .string(clientName),
                "tabs": .array(items),
            ]))
    }

    /// Everyone else's records, newest device first.
    static func parse(_ records: [DecryptedRecord], ourGUID: String, clients: [String: SyncDeviceRecord])
        -> [RemoteDeviceTabs]
    {
        records
            .filter { $0.id != ourGUID && !$0.isDeleted }
            .compactMap { record -> RemoteDeviceTabs? in
                let tabs = (record.payload["tabs"]?.arrayValue ?? []).compactMap {
                    item -> RemoteTabItem? in
                    guard let first = item["urlHistory"]?.arrayValue?.first?.stringValue,
                        let url = URL(string: first)
                    else { return nil }
                    return RemoteTabItem(
                        title: item["title"]?.stringValue ?? "",
                        url: url,
                        lastUsed: Date(
                            timeIntervalSince1970: item["lastUsed"]?.doubleValue ?? 0),
                        icon: item["icon"]?.stringValue.flatMap(URL.init(string:)))
                }
                guard !tabs.isEmpty else { return nil }
                let client = clients[record.id]
                return RemoteDeviceTabs(
                    clientGUID: record.id,
                    clientName: record.payload["clientName"]?.stringValue
                        ?? client?.name ?? "Another device",
                    deviceType: client?.type ?? "desktop",
                    tabs: tabs.sorted { $0.lastUsed > $1.lastUsed },
                    lastModified: Date(timeIntervalSince1970: record.modified))
            }
            .sorted { $0.lastModified > $1.lastModified }
    }
}
