//  SecurityBadge.swift
//  What the glyph at the left of the URL pill is saying — and what tapping it
//  should do about it.
//
//  Before this it said one of two things and did neither: a padlock for https
//  and a warning triangle for everything else, both inert. The triangle is the
//  single most important control in the bar when something is wrong — it is
//  the only place the certificate prompt, the trusted-certificate record and
//  the failure detail can be reached once the page has settled (#0089A).

import Foundation

enum SecurityBadge: Equatable {
    /// The start page: nothing loaded, nothing to say.
    case search
    /// HTTPS, and the system trusted the chain on its own.
    case secure
    /// HTTPS whose certificate *you* approved — a homelab box. Tapping shows
    /// the record and offers to forget it.
    case trusted(TrustedCertificate)
    /// A TLS prompt is waiting on this host. Tapping brings it back.
    case challenge
    /// Plain HTTP. Nothing is encrypted; tapping explains that.
    case insecure
    /// The load failed. Tapping shows what went wrong.
    case failed(LoadFailure)

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .secure: return "lock.fill"
        case .trusted: return "lock.badge.checkmark.fill"
        case .challenge, .insecure, .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Whether tapping the glyph does anything. A padlock on an ordinary HTTPS
    /// page has nothing to add, so it stays a glyph rather than becoming a
    /// button that does nothing — a control that does nothing is worse than no
    /// control.
    var isActionable: Bool {
        switch self {
        case .search, .secure: return false
        case .trusted, .challenge, .insecure, .failed: return true
        }
    }

    /// Tinted only where it is carrying a warning; a padlock in accent colour
    /// reads as a *claim* about safety, which is not ours to make.
    var isWarning: Bool {
        switch self {
        case .challenge, .insecure, .failed: return true
        case .search, .secure, .trusted: return false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .search: return "Search"
        case .secure: return "Connection is secure"
        case .trusted: return "Certificate approved by you. Show details"
        case .challenge: return "Certificate needs your approval. Show the prompt"
        case .insecure: return "Connection is not encrypted. Show details"
        case .failed: return "This page did not load. Show details"
        }
    }
}

/// What the badge opens. Root-level so it can cover a split pane or a glance
/// card, neither of which can present a sheet that covers the whole window.
enum SecurityDetail: Identifiable, Equatable {
    case trusted(certificate: TrustedCertificate)
    case insecure(host: String)
    case failed(LoadFailure)

    var id: String {
        switch self {
        case .trusted(let certificate): return "trusted-\(certificate.id.uuidString)"
        case .insecure(let host): return "insecure-\(host)"
        case .failed(let failure): return "failed-\(failure.id)"
        }
    }
}
