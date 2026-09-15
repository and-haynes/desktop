//  ContentBlocker.swift
//  Compiles the Focus blocklist into a WKContentRuleList.
//
//  WebKit compiles the JSON into a bytecode program once and caches it in the
//  rule-list store, so the cost is paid on first use and the list is applied
//  entirely inside the content process — the app never sees the requests it is
//  blocking, which is the point.

import Foundation
import WebKit

/// `WKContentRuleListStore.default()` is main-actor isolated (and `cached` is
/// shared mutable state), so the whole enum is pinned to the main actor rather
/// than reaching across from a nonisolated context.
@MainActor
enum ContentBlocker {
    /// Bumping this invalidates WebKit's compiled cache. Change it whenever the
    /// JSON changes, or an old install keeps running the old rules forever.
    static let identifier = "zen.focus.blocklist.v1"

    private static var cached: WKContentRuleList?

    enum CompileError: Error, LocalizedError {
        case resourceMissing
        case compilationFailed(String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "The blocklist resource is missing from the app bundle."
            case .compilationFailed(let reason):
                return "The blocklist could not be compiled: \(reason)"
            }
        }
    }

    /// Anchors `Bundle(for:)` on the app module, so the resource is found from
    /// a unit-test bundle too — `Bundle.main` is the test runner there, not us.
    private final class BundleMarker {}

    /// The raw rule JSON, exposed so tests can validate it without WebKit.
    static func blocklistJSON(in bundle: Bundle? = nil) throws -> String {
        let candidates = [bundle, Bundle(for: BundleMarker.self), .main].compactMap { $0 }
        for candidate in candidates {
            if let url = candidate.url(forResource: "focus-blocklist", withExtension: "json"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            {
                return text
            }
        }
        throw CompileError.resourceMissing
    }

    /// Compile (or fetch from WebKit's cache) the Focus rule list.
    /// Returns nil rather than throwing at the call site — a blocklist that
    /// will not compile should degrade to "no blocking", not "no browser".
    @discardableResult
    static func focusRuleList() async -> WKContentRuleList? {
        if let cached { return cached }
        let store = WKContentRuleListStore.default()

        // Ask for the already-compiled list first; compiling ~200 rules takes
        // long enough to notice on every Focus entry.
        if let existing = try? await store?.contentRuleList(forIdentifier: identifier) {
            cached = existing
            return existing
        }

        guard let json = try? blocklistJSON() else {
            assertionFailure("Zen: focus-blocklist.json is not in the bundle")
            return nil
        }
        do {
            let compiled = try await store?.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json)
            cached = compiled
            return compiled
        } catch {
            assertionFailure("Zen: blocklist failed to compile: \(error)")
            return nil
        }
    }

    /// Drop the in-process handle. WebKit keeps its own compiled cache, so this
    /// is only about not holding the object across an erase.
    static func forgetCachedList() {
        cached = nil
    }
}
