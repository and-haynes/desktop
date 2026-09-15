//  ExtensionIconView.swift
//  An extension's icon, from whichever of the three places actually has one.
//
//  A loaded extension's icon comes from WebKit (`WKWebExtensionAction.icon`),
//  already resolved through the icon set and the locale. An *installed but not
//  loaded* one — disabled, or on iOS 17 — has no WebKit object at all, so the
//  icon is read straight out of the unpacked package using the path the
//  manifest declared. A package with no icon gets the puzzle piece, which is
//  the symbol the whole feature is labelled with.

import SwiftUI
import UIKit

struct ExtensionIconView: View {
    let record: InstalledExtension
    /// The live action icon, when the extension is loaded.
    var actionIcon: Data?
    var size: CGFloat = 28
    var directory: URL?
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Group {
            if let image = resolvedImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    palette.accent.withAlpha(0.22).color
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: size * 0.52))
                        .foregroundStyle(palette.accent.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .opacity(record.isEnabled ? 1 : 0.45)
        .saturation(record.isEnabled ? 1 : 0.2)
        .accessibilityHidden(true)
    }

    private var resolvedImage: UIImage? {
        if let actionIcon, let image = UIImage(data: actionIcon) { return image }
        guard let directory, let path = record.iconPath else { return nil }
        // The manifest's path is relative to the package, and may be written
        // with a leading slash by a bundler that thinks it is a web path.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = directory.appendingPathComponent(trimmed)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
