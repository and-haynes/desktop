//  CSSColor.swift
//  Reading a colour back out of a live document.
//
//  `getComputedStyle(el).backgroundColor` always resolves to `rgb(r, g, b)` or
//  `rgba(r, g, b, a)` — never a keyword, never a hex — so this parser only has
//  to understand those two forms. It exists because WebKit will not tell us a
//  page's background colour any other way: `underPageBackgroundColor` comes
//  back clear while the web view is transparent, and it has to be transparent
//  so a space's gradient shows through before the first paint (#008A9).
//
//  Separate from `ColorParsing`, which is about what a *person* typed and owes
//  them an error message. This one either understands the string or shrugs.

import Foundation
import UIKit

/// A colour as the document reports it. Alpha matters: a page that sets no
/// background of its own computes to `rgba(0, 0, 0, 0)`, and treating that as
/// black is exactly the "black slab" bug.
struct CSSColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// Nothing is painted, so there is nothing to borrow.
    var isTransparent: Bool { alpha <= 0.001 }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// `rgb(34, 34, 34)`, `rgba(255, 255, 255, 0.5)`, and the space-separated
    /// `rgb(34 34 34 / 50%)` form newer WebKit can emit. Percentages are
    /// accepted for alpha only, which is the only place they appear.
    static func parse(_ text: String) -> CSSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("rgb"), let open = trimmed.firstIndex(of: "("),
            let close = trimmed.lastIndex(of: ")"), open < close
        else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<close])
        let parts =
            inner
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        var channels: [Double] = []
        for part in parts.prefix(3) {
            guard let value = Double(part), value >= 0, value <= 255 else { return nil }
            channels.append(value / 255)
        }
        var alpha = 1.0
        if parts.count == 4 {
            let raw = parts[3]
            if raw.hasSuffix("%") {
                guard let percent = Double(raw.dropLast()) else { return nil }
                alpha = percent / 100
            } else {
                guard let value = Double(raw) else { return nil }
                alpha = value
            }
            guard alpha >= 0, alpha <= 1 else { return nil }
        }
        return CSSColor(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }
}
