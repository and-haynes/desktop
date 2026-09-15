//  AppearanceMode.swift
//  Follow system / Light / Dark — the three Zen desktop offers
//  (`zen.view.window.scheme` 2 / 1 / 0).

import Foundation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `zen.view.window.scheme = 2`
    case system
    /// `zen.view.window.scheme = 1`
    case light
    /// `zen.view.window.scheme = 0`
    case dark
    /// Not a Zen desktop scheme. Warm paper chrome derived by the same
    /// `color-mix` chain from a paper/ink pair instead of a grey one (#00890).
    case sepia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .sepia: return "book.closed"
        }
    }

    /// What SwiftUI should force, or nil to let the system decide.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        // Sepia is a light scheme: the system controls inside our sheets have
        // to render light or they fight the paper.
        case .sepia: return .light
        case .dark: return .dark
        }
    }

    /// Which branding pair the palette derives from.
    func surfaceBase(systemDark: Bool, spacePrefersDark: Bool?) -> ZenSurfaceBase {
        if self == .sepia { return .sepia }
        return isDark(systemDark: systemDark, spacePrefersDark: spacePrefersDark)
            ? .dark : .light
    }

    /// Resolve to the boolean `ZenPalette` wants.
    ///
    /// An explicit choice beats the space's own `shouldBeDarkMode()` heuristic:
    /// upstream only applies that when the scheme is set to "default", and a
    /// person who picked Light meant it.
    func isDark(systemDark: Bool, spacePrefersDark: Bool?) -> Bool {
        switch self {
        case .light, .sepia: return false
        case .dark: return true
        case .system: return spacePrefersDark ?? systemDark
        }
    }
}
