//  SyncDiagnostics.swift
//  A timestamped transcript of a sign-in, because "nothing happened" is not a
//  bug report.
//
//  #008AA was exactly that: the Mozilla form rendered, the password went in,
//  and the sheet sat there. Nothing in the app could say whether the page had
//  loaded, whether it had asked us anything, or whether a code had ever come
//  back — the whole flow was invisible between "sheet opened" and "signed in".
//
//  So every step of the flow writes a line here, success or failure, and the
//  failures also raise an alert carrying the underlying error rather than a
//  status row that says "Sign-in failed". The log is readable in
//  Settings → Sync → Sync diagnostics and copyable in one tap, so the next
//  time it stops, it stops *somewhere nameable*.
//
//  Nothing secret is written: no password, no authorization code, no token,
//  no refresh token. Where a value matters only by its presence or its shape,
//  the line records the shape (`code: 64 chars`), never the value.

import Foundation

@MainActor
final class SyncDiagnostics: ObservableObject {

    /// The steps of a sign-in and first sync, in the order they should happen.
    /// A transcript that stops is read by looking for the last one present.
    enum Step: String, CaseIterable, Sendable {
        case authorizeOpened = "Authorization opened"
        case pageLoaded = "Sign-in page loaded"
        case webChannel = "WebChannel message"
        case fxaStatus = "fxa_status"
        case canLinkAccount = "can_link_account"
        case oauthLogin = "oauth_login"
        case codeExchange = "Code exchange"
        case keysDecrypted = "Scoped key"
        case tokenServer = "Token server"
        case storageNode = "Storage node"
        case firstSync = "Sync"
        case signedOut = "Signed out"
    }

    enum Outcome: String, Sendable {
        case note
        case ok
        case failed
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id = UUID()
        let at: Date
        let step: Step
        let outcome: Outcome
        let detail: String

        var symbol: String {
            switch outcome {
            case .note: return "circle.dashed"
            case .ok: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }
    }

    /// A failure worth interrupting for. `Identifiable` so it can drive an
    /// `.alert(item:)`.
    struct Failure: Identifiable, Equatable, Sendable {
        let id = UUID()
        let step: Step
        let message: String
    }

    /// Oldest first — this is a transcript, and a transcript read backwards is
    /// harder to follow than one that is a little scrolling.
    @Published private(set) var entries: [Entry] = []

    /// Set when a step fails. The Settings screen presents it and clears it.
    @Published var failure: Failure?

    /// Bounded: a long-running app should not accumulate a log it never shows.
    static let capacity = 200

    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Writing

    func log(_ step: Step, _ detail: String = "", outcome: Outcome = .note) {
        entries.append(Entry(at: now(), step: step, outcome: outcome, detail: detail))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func succeeded(_ step: Step, _ detail: String = "") {
        log(step, detail, outcome: .ok)
    }

    /// Record a failure *and* raise it. A failure that only lands in the log is
    /// the bug this file exists to stop.
    func failed(_ step: Step, _ error: Error) {
        failed(step, message: Self.describe(error))
    }

    func failed(_ step: Step, message: String) {
        // One failure, one line. A step that fails deep in the stack is
        // reported where it happened *and* summarised by its caller; logging
        // both would put the same sentence in the transcript twice and flash
        // two alerts for one problem.
        if let last = entries.last, last.outcome == .failed, last.detail == message {
            return
        }
        log(step, message, outcome: .failed)
        failure = Failure(step: step, message: message)
    }

    func clear() {
        entries.removeAll()
        failure = nil
    }

    /// Start of a fresh attempt: the previous transcript is noise once a new
    /// sign-in begins, and keeping it invites reading the wrong run.
    func beginAttempt() {
        entries.removeAll()
        failure = nil
    }

    // MARK: Reading

    var lastStep: Step? { entries.last?.step }

    var hasFailure: Bool { entries.contains { $0.outcome == .failed } }

    /// One tap in the diagnostics screen puts this on the pasteboard, which is
    /// what gets quoted on a ticket.
    var transcript: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { entry in
            let mark =
                switch entry.outcome {
                case .note: "·"
                case .ok: "✓"
                case .failed: "✗"
                }
            let detail = entry.detail.isEmpty ? "" : " — \(entry.detail)"
            return "\(formatter.string(from: entry.at)) \(mark) \(entry.step.rawValue)\(detail)"
        }
        .joined(separator: "\n")
    }

    /// `localizedDescription` on a `SyncError` is the message we wrote; on
    /// anything else it can be useless ("The operation couldn't be
    /// completed"), so the domain and code go alongside it.
    static func describe(_ error: Error) -> String {
        if let syncError = error as? SyncError {
            return syncError.errorDescription ?? String(describing: syncError)
        }
        let nsError = error as NSError
        let description = nsError.localizedDescription
        return "\(description) [\(nsError.domain) \(nsError.code)]"
    }

    /// A value whose *shape* is the interesting part. Never log the value: an
    /// authorization code is a bearer credential for the seconds it lives.
    static func shape(_ value: String?, label: String) -> String {
        guard let value, !value.isEmpty else { return "\(label): missing" }
        return "\(label): \(value.count) chars"
    }
}
