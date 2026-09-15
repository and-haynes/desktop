//  FxASignInFlow.swift
//  The sign-in sheet.
//
//  This is the path we would rather be on — the password is typed into Safari's
//  own process, not into a web view this app could read — and it is **not the
//  one in use**. `ASWebAuthenticationSession` matches a callback by scheme, and
//  Mozilla's authorization endpoint rejects every redirect that is not
//  `http(s)`; the evidence is at the top of `SyncConfig.swift`.
//
//  It is kept, compiled and behind `SyncConfig.usesSystemAuthSession`, because
//  the day Zen has an OAuth client id of its own with a Zen scheme registered,
//  this file and two constants are the whole change. Deleting it would mean
//  rediscovering all of that.

#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif
import Foundation
import UIKit

@MainActor
final class FxASignInFlow: NSObject {

    private var session: ASWebAuthenticationSession?

    /// Runs the whole thing: sheet → code → tokens. Throws
    /// `SyncError.cancelled` when the user dismisses the sheet, which callers
    /// should treat as "nothing happened" rather than as a failure.
    func signIn(client: FxAOAuthClient, email: String? = nil) async throws -> FxAOAuthTokens {
        let request = try client.authorizationRequest(email: email)
        let callback = try await present(request)
        let code = try FxAOAuthClient.authorizationCode(
            fromCallback: callback, expectedState: request.state)
        return try await client.exchange(code: code, request: request)
    }

    private func present(_ request: FxAAuthorizationRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: request.url, callbackURLScheme: SyncConfig.redirectScheme
            ) { url, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: SyncError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: SyncError.message(error.localizedDescription))
                    }
                    return
                }
                guard let url else {
                    continuation.resume(throwing: SyncError.cancelled)
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            // Share Safari's cookies: an account already signed in on this
            // phone should not have to type a password again.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(
                    throwing: SyncError.message(
                        "Could not open the Mozilla account sign-in page."))
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

extension FxASignInFlow: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor
    {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}
