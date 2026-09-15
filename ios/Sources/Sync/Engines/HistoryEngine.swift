//  HistoryEngine.swift
//  The `history` collection.
//
//  A record is a page and a list of visits: `{ id, histUri, title, visits: [{
//  date, type }] }`, where `date` is **microseconds** since the epoch — the
//  one unit in the whole protocol that is neither seconds nor milliseconds,
//  and the usual reason a client's history all lands in 1970.
//
//  History is large and mostly write-only, so this is deliberately bounded: we
//  publish the most recent pages rather than everything, and we merge incoming
//  visits into our own store without trying to reconstruct a visit graph we
//  have no use for.

import Foundation

enum HistoryEngine {
    static let collection = "history"

    /// How many of our newest pages to publish per sync. Firefox's own initial
    /// upload is capped too; an unbounded first sync on a metered connection
    /// is a poor introduction.
    static let uploadLimit = 500
    /// Visits per record. The server rejects records over ~256 KB.
    static let maxVisitsPerRecord = 20

    /// `TRANSITION_LINK`. We cannot distinguish typed from followed, and
    /// claiming otherwise would corrupt the desktop's frecency ranking.
    static let transitionLink = 1

    static func guid(for url: URL) -> String {
        SyncGUID.derived(from: url.absoluteString)
    }

    static func outgoing(entries: [HistoryEntry], shadow: CollectionShadow)
        -> [DecryptedRecord]
    {
        var records: [DecryptedRecord] = []
        for entry in entries.prefix(uploadLimit)
        where entry.url.scheme == "http" || entry.url.scheme == "https" {
            let id = guid(for: entry.url)
            // We keep one timestamp and a count, not a visit list, so the
            // record carries the visit we know about. Older visits already on
            // the server are preserved by the desktop's own merge.
            let payload = JSONValue.object([
                "id": .string(id),
                "histUri": .string(entry.url.absoluteString),
                "title": .string(entry.title),
                "visits": .array([
                    .object([
                        "date": .number(
                            (entry.lastVisited.timeIntervalSince1970 * 1_000_000).rounded()),
                        "type": .number(Double(transitionLink)),
                    ])
                ]),
            ])
            if shadow.uploaded[id] != payload.digest {
                records.append(DecryptedRecord(id: id, modified: 0, payload: payload))
            }
        }
        return records
    }

    struct IncomingVisit: Equatable, Sendable {
        var url: URL
        var title: String
        var lastVisited: Date
        var visitCount: Int
    }

    static func applyIncoming(_ records: [DecryptedRecord], shadow: inout CollectionShadow)
        -> [IncomingVisit]
    {
        var visits: [IncomingVisit] = []
        for record in records {
            if record.isDeleted {
                shadow.noteApplied(id: record.id, payload: nil)
                continue
            }
            guard let urlString = record.payload["histUri"]?.stringValue,
                let url = URL(string: urlString),
                url.scheme == "http" || url.scheme == "https"
            else {
                shadow.noteApplied(id: record.id, payload: record.payload)
                continue
            }
            let dates =
                (record.payload["visits"]?.arrayValue ?? [])
                .compactMap { $0["date"]?.doubleValue }
            guard let newest = dates.max() else {
                shadow.noteApplied(id: record.id, payload: record.payload)
                continue
            }
            visits.append(
                IncomingVisit(
                    url: url,
                    title: record.payload["title"]?.stringValue ?? "",
                    // Microseconds. This division is the whole reason the unit
                    // is called out at the top of the file.
                    lastVisited: Date(timeIntervalSince1970: newest / 1_000_000),
                    visitCount: dates.count))
            shadow.noteApplied(id: record.id, payload: record.payload)
        }
        return visits
    }
}
