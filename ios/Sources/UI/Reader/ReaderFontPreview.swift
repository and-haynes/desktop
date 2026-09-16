//  ReaderFontPreview.swift
//  Drawing a reader face in SwiftUI, for the specimens (#008BC).
//
//  The reader itself renders in CSS and never touches this. But the chips in
//  the control panel and the live specimen in Settings both have to *show* a
//  face, and a chip labelled "Georgia" drawn in San Francisco is a chip that
//  lies about what it does. So the named families are asked for by name, and
//  only the four system families — which have no stable PostScript name to ask
//  for — go through `Font.Design`.

import SwiftUI

extension ReaderFont {
    /// The family name to hand `Font.custom`, or nil for a system family.
    var previewFamilyName: String? {
        switch self {
        case .systemSerif, .systemSans, .systemRounded, .systemMono: return nil
        case .newYork: return "New York"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .avenir: return "Avenir Next"
        }
    }

    /// Used for the system families, and as the fallback if a named family is
    /// ever missing from a future device.
    var previewDesign: Font.Design {
        switch self {
        case .systemMono: return .monospaced
        case .systemRounded: return .rounded
        default: return isSerif ? .serif : .default
        }
    }

    /// A SwiftUI font for a specimen at `size`.
    ///
    /// `Font.custom(_:size:)` falls back to the system font when the family is
    /// not installed, so this degrades to something readable rather than to
    /// nothing — but it degrades to *San Francisco*, not to the right kind of
    /// type, which is why the system families do not go through it.
    func previewFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let name = previewFamilyName else {
            return .system(size: size, weight: weight, design: previewDesign)
        }
        return .custom(name, size: size).weight(weight)
    }
}
