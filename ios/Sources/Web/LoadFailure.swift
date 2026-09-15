//  LoadFailure.swift
//  Why a page did not load, and what to offer instead (#0089A).
//
//  The bug this exists for: typing a LAN address that nothing answers on left
//  a blank page and a warning glyph with no explanation and nothing to tap.
//  A browser that fails silently is worse than one that fails loudly — you
//  cannot tell a typo from a dead host from a permissions problem.

import Foundation

struct LoadFailure: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Nothing is listening, or the route is dead.
        case cannotConnect
        /// The host answered nothing within our budget.
        case timedOut
        /// DNS could not resolve it.
        case hostNotFound
        /// No route — usually a LAN address the device cannot reach, or the
        /// Local Network permission has not been granted.
        case noNetwork
        /// TLS refused and the owner did not (or could not) approve it.
        case secureConnectionFailed
        /// We understood the URL but will not render it.
        case unsupportedScheme(String)
        case other
    }

    var id: String { "\(url.absoluteString)-\(code)" }

    let url: URL
    let kind: Kind
    /// The underlying NSURLError code, shown small — it is the thing worth
    /// pasting into a search when nothing else helps.
    let code: Int
    let localizedDescription: String

    var host: String { url.host ?? url.absoluteString }

    /// The port actually used, explicit or implied by the scheme.
    var port: Int {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }

    var usedDefaultPort: Bool { url.port == nil }

    var isLocalNetwork: Bool { LANHost.isLocalNetwork(url.host) }

    var title: String {
        switch kind {
        case .cannotConnect: return "\(host) didn't answer"
        case .timedOut: return "\(host) took too long"
        case .hostNotFound: return "Can't find \(host)"
        case .noNetwork: return "Can't reach \(host)"
        case .secureConnectionFailed: return "Can't connect securely to \(host)"
        case .unsupportedScheme(let scheme): return "Can't open \(scheme): links"
        case .other: return "Can't open \(host)"
        }
    }

    var message: String {
        switch kind {
        case .cannotConnect:
            return usedDefaultPort
                ? "Nothing is listening on port \(port). It may be on a different port."
                : "Nothing is listening on port \(port)."
        case .timedOut:
            return "No reply from port \(port) within \(Int(LoadFailure.timeout)) seconds."
        case .hostNotFound:
            return "That name could not be looked up. Check the spelling."
        case .noNetwork:
            return isLocalNetwork
                ? "Zen may not have permission to reach devices on your network."
                : "There is no route to that address."
        case .secureConnectionFailed:
            return "The secure connection could not be established."
        case .unsupportedScheme:
            return "Zen can only open web pages."
        case .other:
            return localizedDescription
        }
    }

    /// How long we give a page before calling it. WebKit's own default is a
    /// minute, which for a LAN host that simply is not there is a minute of
    /// staring at nothing.
    static let timeout: TimeInterval = 10

    /// Ports worth offering when the default one was refused. Chosen because
    /// they are what homelab services actually sit on — 8006 is Proxmox, 8443
    /// and 8080 are the usual alternates.
    static let commonPorts = [8006, 8080, 8443, 8000, 9090]

    /// One-tap alternatives for this failure, best first.
    func suggestions() -> [Suggestion] {
        var out: [Suggestion] = []

        // The other scheme is the single most likely fix on a home network,
        // where plenty of devices serve only one of the two.
        if let flipped = urlWithFlippedScheme() {
            let scheme = flipped.scheme == "https" ? "https" : "http"
            out.append(Suggestion(label: "Try \(scheme)://", url: flipped))
        }

        // Only offer ports when the failure was actually a port problem and
        // the user did not already name one.
        if usedDefaultPort, kind == .cannotConnect || kind == .timedOut {
            for port in Self.commonPorts {
                guard let candidate = url.withPort(port) else { continue }
                out.append(Suggestion(label: ":\(port)", url: candidate))
            }
        }
        return out
    }

    struct Suggestion: Identifiable, Equatable, Sendable {
        var id: String { url.absoluteString }
        let label: String
        let url: URL
    }

    private func urlWithFlippedScheme() -> URL? {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme == "https" ? "http" : "https"
        // A URL that named its port keeps it; one that did not must not
        // inherit the old scheme's default.
        return components?.url
    }

    /// Classify an NSError from WebKit.
    static func classify(_ error: Error, url: URL) -> LoadFailure? {
        let nsError = error as NSError
        // A cancelled load is normal — a redirect, or the user tapping again.
        guard nsError.code != NSURLErrorCancelled else { return nil }

        let kind: Kind
        switch nsError.code {
        case NSURLErrorCannotConnectToHost:
            kind = .cannotConnect
        case NSURLErrorTimedOut:
            kind = .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            kind = .hostNotFound
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            kind = .noNetwork
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired:
            kind = .secureConnectionFailed
        case NSURLErrorUnsupportedURL:
            kind = .unsupportedScheme(url.scheme ?? "that")
        default:
            kind = .other
        }
        return LoadFailure(
            url: url, kind: kind, code: nsError.code,
            localizedDescription: nsError.localizedDescription)
    }

    /// The watchdog's synthetic failure, for when WebKit neither commits nor
    /// reports — which is exactly what a black-holed LAN address does.
    static func timeoutFailure(url: URL) -> LoadFailure {
        LoadFailure(
            url: url, kind: .timedOut, code: NSURLErrorTimedOut,
            localizedDescription: "The request timed out.")
    }
}

extension URL {
    /// The same URL on a different port.
    func withPort(_ port: Int) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.port = port
        return components?.url
    }
}
