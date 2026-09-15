//  SchemePrefill.swift
//  Typing `10.` in the URL bar means you are going to a box on your network,
//  and a box on your network almost always wants `https://` (#0089B).
//
//  Upstream has nothing like this — a desktop urlbar has Firefox's fixup and a
//  keyboard with a comfortable `/`. On a phone the scheme is eight characters
//  on two keyboard planes, typed before every single homelab address, and
//  leaving it off is not harmless: without it the bar guesses HTTP, and a
//  Proxmox box at :8006 answers that with nothing at all.
//
//  The rule is deliberately narrow, because a URL bar that rewrites what you
//  typed is infuriating the first time it is wrong:
//
//  - Only the three RFC 1918 leading octets, and only as the *whole* field.
//  - Only when typed. A paste is a decision someone already made.
//  - Never when a scheme is already there.
//  - Never again in the same edit once the user has deleted it — saying "no"
//    to an autocomplete should mean no, not "ask me again next keystroke".
//
//  What it inserts is ordinary editable text, not a decoration: the caret sits
//  exactly where it would have, and backspace deletes it like anything else.

import Foundation

enum SchemePrefill {
    static let scheme = "https://"

    /// The RFC 1918 leading octets. `169.254.` (link-local) is deliberately
    /// absent — nobody types a self-assigned address on purpose.
    static let triggers = ["10.", "192.", "172."]

    /// The text and caret position after the change has been applied.
    struct Edit: Equatable {
        var text: String
        /// Offset in characters from the start of the string.
        var caret: Int
    }

    /// What the field should hold, or nil to leave the edit alone.
    ///
    /// - Parameters:
    ///   - text: the field contents *after* the user's change.
    ///   - caret: where the caret would be after the user's change.
    ///   - isPaste: true when the change inserted more than one character.
    ///   - userRemovedScheme: true once the user has deleted an inserted
    ///     scheme during this edit.
    static func edit(
        text: String, caret: Int, isPaste: Bool = false, userRemovedScheme: Bool = false
    ) -> Edit? {
        guard !isPaste, !userRemovedScheme else { return nil }
        guard !text.lowercased().contains("://") else { return nil }
        // Only when the trigger *is* the whole field: "10." fires, but
        // "ratio 10." and "9.10." do not.
        guard triggers.contains(text) else { return nil }
        // …and only when it was typed at the end. A caret parked mid-string is
        // someone editing, not someone starting an address.
        guard caret == text.count else { return nil }
        return Edit(text: scheme + text, caret: caret + scheme.count)
    }

    /// True when a change removes a leading scheme.
    ///
    /// Only meaningful for a scheme *this* code inserted — the caller has to
    /// know that, because the omnibox opens prefilled with the current URL and
    /// typing over `https://example.com` looks identical from here.
    static func removesScheme(previous: String, updated: String) -> Bool {
        previous.lowercased().hasPrefix(scheme) && !updated.lowercased().hasPrefix(scheme)
    }
}
