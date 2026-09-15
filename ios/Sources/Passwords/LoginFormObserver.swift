//  LoginFormObserver.swift
//  Hearing that a login form was submitted, so the vault can offer to keep it
//  (#008AD).
//
//  Installed by `WebViewPool` on each web view it creates, and only when a
//  vault is actually configured — a build with no vault connected injects
//  nothing into page content at all, which keeps the `ios` branch's promise
//  (#008AB) true for everybody who has not opted in.
//
//  ## Why this is safe to inject, when #008AB says not to inject
//
//  The rule on `ios` is that Zen puts nothing into page content, because a
//  script that *rewrites* a login form — renames fields, re-parents inputs,
//  intercepts focus — is one of the ways iOS Password AutoFill goes quiet, with
//  no error to explain it. `LoginFormFill.submitObserverScript` is on the other
//  side of that line: two capturing event listeners that read values and post a
//  message. No attribute is written, no node is moved, nothing takes focus. The
//  form iOS inspects is bit-for-bit the form the site shipped.
//
//  That is an argument, not a proof, so `PasswordsAutoFillTests` checks the two
//  coexist rather than asserting it in a comment and hoping.
//
//  ## Trust
//
//  Everything arriving here came from a web page and is therefore hostile until
//  checked. `SubmittedCredential.init?(messageBody:)` does the checking; this
//  class adds the one check it cannot: that the message's URL is the page the
//  web view is actually on. Without it, a hostile frame could post a credential
//  attributed to `bank.com` and the save prompt would offer to file it there.

import Foundation
import WebKit

@MainActor
final class LoginFormObserver: NSObject, WKScriptMessageHandler {

    private weak var vault: PasswordVaultService?

    init(vault: PasswordVaultService) {
        self.vault = vault
    }

    /// Add the listener script and this handler to a fresh configuration.
    ///
    /// `.atDocumentEnd` so the form exists by the time the listeners go on, and
    /// `forMainFrameOnly: false` because plenty of sign-in forms are in an
    /// iframe — the frame check below is what makes that safe.
    static func install(on configuration: WKWebViewConfiguration, vault: PasswordVaultService)
        -> LoginFormObserver
    {
        let observer = LoginFormObserver(vault: vault)
        let controller = configuration.userContentController
        controller.add(observer, name: LoginFormFill.submitMessageHandler)
        controller.addUserScript(
            WKUserScript(
                source: LoginFormFill.submitObserverScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false))
        return observer
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == LoginFormFill.submitMessageHandler else { return }
        guard let credential = SubmittedCredential(messageBody: message.body) else { return }

        // The page's own claim about where it is, checked against WebKit's.
        // `message.frameInfo.securityOrigin` is the frame's real origin and is
        // not something page script can forge.
        let origin = message.frameInfo.securityOrigin
        guard let host = credential.url.host,
            DomainMatching.normaliseHost(host)
                == DomainMatching.normaliseHost(origin.host)
        else {
            return
        }

        // http pages are not offered: storing a credential typed into a page
        // that anybody on the path could have rewritten is not a favour.
        guard credential.url.scheme?.lowercased() == "https" else { return }

        vault?.noteSubmittedCredential(credential)
    }
}
