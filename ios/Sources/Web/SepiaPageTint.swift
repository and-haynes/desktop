//  SepiaPageTint.swift
//  Optionally warm the *page* as well as the chrome, in Sepia (#00890).
//
//  Off by default and deliberately so: a filter over someone else's design is a
//  blunt instrument, it fights sites that already have a dark or warm theme,
//  and whether you want it is a matter of taste rather than a correctness
//  question the browser can answer for you.
//
//  It is an overlay, not `filter:` on the root element. A CSS filter on `html`
//  establishes a containing block, which silently breaks `position: fixed` on a
//  large fraction of the web — sticky headers detach, modals land in the wrong
//  place. A fixed, non-interactive, multiply-blended sheet over the top tints
//  the same way and changes no layout at all.

import Foundation
import WebKit

enum SepiaPageTint {
    static let elementID = "zen-sepia-tint"

    /// The paper colour the chrome uses, so page and chrome agree.
    static let tintHex = "#F4ECD8"

    /// Idempotent: safe to run on every navigation and every settings change.
    static func script(enabled: Bool) -> String {
        """
        (function () {
          var id = '\(elementID)';
          var existing = document.getElementById(id);
          if (!\(enabled ? "true" : "false")) {
            if (existing) { existing.remove(); }
            return;
          }
          if (existing) { return; }
          var root = document.body || document.documentElement;
          if (!root) { return; }
          var sheet = document.createElement('div');
          sheet.id = id;
          sheet.setAttribute('aria-hidden', 'true');
          sheet.style.cssText = [
            'position:fixed', 'inset:0', 'pointer-events:none',
            'z-index:2147483647', 'background:\(tintHex)',
            'mix-blend-mode:multiply'
          ].join(';');
          root.appendChild(sheet);
        })();
        """
    }

    /// Injected at document end so new pages come up already warm rather than
    /// flashing white and then tinting.
    static func userScript(enabled: Bool) -> WKUserScript {
        WKUserScript(
            source: script(enabled: enabled), injectionTime: .atDocumentEnd,
            forMainFrameOnly: false)
    }
}
