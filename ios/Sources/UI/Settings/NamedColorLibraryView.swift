//  NamedColorLibraryView.swift
//  The name and code lookups that sit under the colour wheel (#0088F).
//
//  The wheel is good for finding a colour and hopeless for finding *the*
//  colour. "The blue from the brand deck" is a name or a code, and neither is
//  a position on a disc.

import SwiftUI
import UniformTypeIdentifiers

struct NamedColorLibraryView: View {
    @ObservedObject var palettes: ImportedPaletteStore
    /// Called with the colour the user picked.
    let onPick: (ZenColor) -> Void

    @Environment(\.zenPalette) private var palette
    @State private var nameQuery = ""
    @State private var codeQuery = ""
    @State private var isImporting = false
    @State private var importError: String?

    private var nameResults: [NamedColor] {
        NamedColorLibrary.search(nameQuery, in: NamedColorLibrary.bundled, limit: 48)
    }

    private var codeResults: [NamedColor] {
        let all = palettes.namedColors
        guard !all.isEmpty else { return [] }
        return NamedColorLibrary.search(codeQuery, in: all, limit: 48)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            nameSection
            codeSection
        }
    }

    // MARK: Names

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Named colours")
            searchField(
                "Search names or paste a hex", text: $nameQuery, identifier: "namedColorSearch")
            if nameResults.isEmpty {
                emptyLine("Nothing called “\(nameQuery)”.")
            } else {
                swatchGrid(nameResults, identifier: "namedColorResults")
            }
            Text(
                "CSS and X11 names from the colour specification, plus a curated set of our own."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Codes

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Code lookup")
            searchField(
                "Search your palette by code", text: $codeQuery, identifier: "paletteCodeSearch")

            if palettes.palettes.isEmpty {
                emptyLine("No palette imported yet.")
            } else if codeResults.isEmpty {
                emptyLine("No code matching “\(codeQuery)”.")
            } else {
                swatchGrid(codeResults, identifier: "paletteCodeResults", showsCode: true)
            }

            HStack(spacing: 10) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import palette…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("importPalette")

                if !palettes.palettes.isEmpty {
                    Menu {
                        ForEach(palettes.palettes) { imported in
                            Button(role: .destructive) {
                                palettes.remove(imported)
                            } label: {
                                Label(
                                    "Remove \(imported.name) (\(imported.entries.count))",
                                    systemImage: "trash")
                            }
                        }
                    } label: {
                        Text("\(palettes.palettes.count) imported")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importError {
                Text(importError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            // The licence note is not fine print — it is the reason the field
            // exists in this shape at all.
            Text(
                "Zen does not ship Pantone, RAL or NCS values: they are licensed, and a table "
                    + "of approximations under those names would be both a licence problem and "
                    + "wrong about the colour. Import your own palette file instead — the "
                    + "format is in the README."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false
        ) { result in
            importError = nil
            switch result {
            case .failure(let error):
                importError = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                load(url)
            }
        }
    }

    private func load(_ url: URL) {
        // A file handed over by the document picker lives outside our sandbox
        // until we ask for it.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let imported = try PaletteImport.parse(data, fallbackName: name)
            palettes.add(imported)
            Haptics.shared.fire(.tabRestore)
        } catch PaletteImport.Failure.notJSON {
            importError = "That file is not JSON."
        } catch PaletteImport.Failure.noColors {
            importError = "No colours in that file — expected a `colors` array."
        } catch PaletteImport.Failure.noUsableColors {
            importError = "No readable hex values in that file."
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func searchField(_ placeholder: String, text: Binding<String>, identifier: String)
        -> some View
    {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.toolbarElementHoverBG.color)
        }
    }

    private func swatchGrid(
        _ colors: [NamedColor], identifier: String, showsCode: Bool = false
    ) -> some View {
        // A fixed height with its own scroll: the picker is already a long
        // screen and 188 swatches would bury everything under it.
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8
            ) {
                ForEach(colors) { entry in
                    swatch(entry, showsCode: showsCode)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 190)
        .accessibilityIdentifier(identifier)
    }

    private func swatch(_ entry: NamedColor, showsCode: Bool) -> some View {
        Button {
            guard let color = entry.color else { return }
            Haptics.shared.fire(.suggestionPick)
            onPick(color)
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(entry.color?.color ?? .clear)
                    .frame(height: 34)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
                    }
                Text(showsCode ? (entry.code ?? entry.name) : entry.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.name), \(entry.hex)")
    }
}
