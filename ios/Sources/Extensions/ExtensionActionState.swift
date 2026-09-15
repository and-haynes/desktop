//  ExtensionActionState.swift
//  The toolbar-button state of one extension, with no WebKit in it.
//
//  `WKWebExtensionAction` needs iOS 18.4. The *bar* does not: the More menu,
//  the action sheet and the settings rows all have to compile and run on
//  iOS 17, where they simply have nothing to show. So the runtime flattens
//  each action into this — a label, a badge and an icon — and every view reads
//  the flattened form.
//
//  It also means the action list is a plain `@Published` array of values:
//  SwiftUI diffing a `WKWebExtensionAction` reference whose badge WebKit
//  mutates in place would never see the change.

import Foundation

struct ExtensionActionState: Equatable, Identifiable, Sendable {
    /// The installed extension's identifier.
    var id: String
    /// The extension's name, for the row.
    var name: String
    /// The action's own label, which an extension may change per tab
    /// ("Enabled on this site" / "Disabled on this site").
    var label: String
    /// `browserAction.setBadgeText`. Empty when there is no badge.
    var badgeText: String = ""
    /// The extension has not gone unread since the badge last changed.
    var hasUnreadBadge: Bool = false
    var isEnabled: Bool = true
    /// Tapping opens a popup rather than firing a click event.
    var presentsPopup: Bool = false
    var hasOptionsPage: Bool = false
    /// PNG bytes for the action icon at bar size, if the extension has one.
    var iconPNG: Data?

    /// What the menu row says under the name.
    var detail: String {
        if !badgeText.isEmpty { return "\(label) · \(badgeText)" }
        return label
    }
}
