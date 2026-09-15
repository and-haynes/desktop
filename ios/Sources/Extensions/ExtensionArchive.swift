//  ExtensionArchive.swift
//  Getting at the files inside an .xpi, a .crx or a plain .zip.
//
//  The three formats a browser is handed are the same format. A Firefox XPI is
//  a ZIP. A Chrome CRX is a short signing header followed by a ZIP. A Safari
//  web extension's resource bundle is a directory. So this file is a ZIP
//  reader and a header-stripper, and everything above it deals in directories.
//
//  **Why write a ZIP reader at all**, when `WKWebExtension` will happily take a
//  ZIP archive as its `resourceBaseURL`? Two reasons, and neither is the
//  loading:
//
//   1. The compatibility scan reads the extension's *JavaScript* — it cannot
//      ask WebKit to hand it a file out of an archive it has not loaded, and
//      the whole point is to report before loading.
//   2. Nothing may be handed to WebKit unexamined. A ZIP entry named
//      `../../Library/Preferences/x.plist` is a real attack on any unpacker
//      that joins paths naively, and an extension arrives from a URL somebody
//      typed. Unpacking ourselves is what lets us refuse.
//
//  Zero dependencies is a standing rule in this project, so: EOCD, central
//  directory, local headers, and `Compression`'s raw-DEFLATE decoder, which is
//  exactly the codec ZIP method 8 stores. Around 200 lines, no ZIP64, no
//  encryption, no multi-disk — none of which a browser extension uses.

import Compression
import Foundation

enum ExtensionArchive {

    enum ArchiveError: LocalizedError, Equatable {
        case notAnArchive
        case truncated
        case unsupportedCompression(UInt16)
        case decompressionFailed(String)
        case unsafeEntryPath(String)
        case missingManifest
        case tooLarge(UInt64)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "This file is not a ZIP, XPI or CRX package."
            case .truncated:
                return "The package is truncated or corrupt."
            case .unsupportedCompression(let method):
                return "The package uses ZIP compression method \(method), which is not supported."
            case .decompressionFailed(let name):
                return "\(name) could not be decompressed."
            case .unsafeEntryPath(let name):
                return "The package contains an entry with an unsafe path (\(name))."
            case .missingManifest:
                return "The package has no manifest.json."
            case .tooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "The package unpacks to %.0f MB, which is too large.", mb)
            }
        }
    }

    /// Ceiling on what a package may expand to. uBlock Origin Lite is around
    /// 3 MB and Dark Reader around 6 MB; 256 MB is far past anything genuine
    /// and well short of filling a phone, which is the zip-bomb case.
    static let maximumUnpackedBytes: UInt64 = 256 * 1_048_576

    // MARK: CRX

    /// Strip a Chrome CRX header, leaving the ZIP. Returns the input unchanged
    /// when it is not a CRX.
    ///
    /// Two formats are in the wild. CRX2 (`Cr24`, version 2) is
    /// `magic|version|pubkeyLen|sigLen`, then those two blobs. CRX3 (version 3)
    /// replaced both with one protobuf header and a single length. We verify
    /// neither signature: the package is about to be shown to the owner
    /// permission by permission and then sandboxed by WebKit, and a signature
    /// we cannot check against a trusted key list proves nothing anyway. The
    /// header is in the way, so it comes off.
    static func strippingCRXHeader(_ data: Data) throws -> Data {
        guard data.count >= 16, data[data.startIndex..<data.startIndex + 4] == Data("Cr24".utf8)
        else { return data }

        let version = readUInt32(data, at: 4)
        let body: Int
        switch version {
        case 2:
            let publicKeyLength = Int(readUInt32(data, at: 8))
            let signatureLength = Int(readUInt32(data, at: 12))
            body = 16 + publicKeyLength + signatureLength
        case 3:
            let headerLength = Int(readUInt32(data, at: 8))
            body = 12 + headerLength
        default:
            throw ArchiveError.notAnArchive
        }
        guard body > 0, body <= data.count else { throw ArchiveError.truncated }
        return data.subdata(in: (data.startIndex + body)..<data.endIndex)
    }

    /// Whether the bytes start with a ZIP local-file or empty-archive signature.
    static func looksLikeZIP(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let signature = readUInt32(data, at: 0)
        return signature == 0x0403_4B50 || signature == 0x0605_4B50 || signature == 0x0807_4B50
    }

    // MARK: Reading

    struct Entry: Equatable {
        var path: String
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var compressionMethod: UInt16
        var localHeaderOffset: UInt64
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// The central directory, in the order the archive lists it.
    static func entries(in data: Data) throws -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(data) else { throw ArchiveError.notAnArchive }
        let count = Int(readUInt16(data, at: eocd + 10))
        var offset = Int(readUInt32(data, at: eocd + 16))
        var result: [Entry] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= data.count, readUInt32(data, at: offset) == 0x0201_4B50 else {
                throw ArchiveError.truncated
            }
            let method = readUInt16(data, at: offset + 10)
            let compressedSize = UInt64(readUInt32(data, at: offset + 20))
            let uncompressedSize = UInt64(readUInt32(data, at: offset + 24))
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let localOffset = UInt64(readUInt32(data, at: offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ArchiveError.truncated }
            let nameData = data.subdata(
                in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength))
            // ZIP names are CP437 unless bit 11 says UTF-8. Every extension
            // toolchain writes UTF-8; the fallback keeps a stray name readable
            // rather than dropping the entry.
            let name =
                String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            result.append(
                Entry(
                    path: name, compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize, compressionMethod: method,
                    localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    /// Decompress one entry.
    static func read(_ entry: Entry, from data: Data) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        let header = Int(entry.localHeaderOffset)
        guard header + 30 <= data.count, readUInt32(data, at: header) == 0x0403_4B50 else {
            throw ArchiveError.truncated
        }
        // The *local* header's name and extra lengths, which are allowed to
        // differ from the central directory's — the extra field usually does.
        let nameLength = Int(readUInt16(data, at: header + 26))
        let extraLength = Int(readUInt16(data, at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + Int(entry.compressedSize)
        guard start <= data.count, end <= data.count else { throw ArchiveError.truncated }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            guard let inflated = inflate(payload, expecting: Int(entry.uncompressedSize)) else {
                throw ArchiveError.decompressionFailed(entry.path)
            }
            return inflated
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// Read one named file without unpacking the archive — what the install
    /// sheet needs to see `manifest.json` before anything touches disk.
    static func read(path: String, from data: Data) throws -> Data {
        let all = try entries(in: data)
        // Some packers nest everything under a single top-level directory.
        // `manifest.json` at the root wins; a single nested copy is accepted.
        if let exact = all.first(where: { $0.path == path }) {
            return try read(exact, from: data)
        }
        let suffix = "/" + path
        let nested = all.filter { $0.path.hasSuffix(suffix) }
        guard nested.count == 1, let entry = nested.first else {
            throw ArchiveError.missingManifest
        }
        return try read(entry, from: data)
    }

    /// The prefix every entry shares, when the archive nests its contents in
    /// one directory. Empty when the manifest is at the root.
    static func rootPrefix(of entries: [Entry]) -> String {
        guard !entries.contains(where: { $0.path == "manifest.json" }) else { return "" }
        let candidates = entries.filter { $0.path.hasSuffix("/manifest.json") }
        guard candidates.count == 1, let manifest = candidates.first else { return "" }
        return String(manifest.path.dropLast("manifest.json".count))
    }

    // MARK: Unpacking

    /// Expand an archive into `destination`, which is created fresh.
    ///
    /// Every entry path is resolved against the destination and checked to be
    /// *inside* it before a single byte is written — `../` in a ZIP entry is
    /// the oldest trick there is, and a browser unpacks archives from wherever
    /// the owner points it.
    @discardableResult
    static func unpack(_ data: Data, to destination: URL) throws -> [String] {
        let all = try entries(in: data)
        guard all.contains(where: { $0.path.hasSuffix("manifest.json") }) else {
            throw ArchiveError.missingManifest
        }
        let total = all.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        guard total <= maximumUnpackedBytes else { throw ArchiveError.tooLarge(total) }

        let prefix = rootPrefix(of: all)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // `standardizedFileURL` on the destination too: Application Support
        // under `/var` is a symlink to `/private/var`, and comparing an
        // unresolved prefix against a resolved child rejects everything.
        let root = destination.standardizedFileURL.resolvingSymlinksInPath().path

        var written: [String] = []
        for entry in all {
            var relative = entry.path
            if !prefix.isEmpty {
                guard relative.hasPrefix(prefix) else { continue }
                relative = String(relative.dropFirst(prefix.count))
            }
            guard !relative.isEmpty else { continue }
            // Signing leftovers: Firefox's META-INF and Chrome's _metadata are
            // not part of the extension and WebKit ignores them.
            if relative.hasPrefix("META-INF/") || relative.hasPrefix("_metadata/") { continue }
            if relative.hasPrefix("__MACOSX/") { continue }

            let target = destination.appendingPathComponent(relative).standardizedFileURL
            let targetPath = target.path
            guard targetPath == root || targetPath.hasPrefix(root + "/") else {
                throw ArchiveError.unsafeEntryPath(entry.path)
            }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = try read(entry, from: data)
            try contents.write(to: target, options: .atomic)
            written.append(relative)
        }
        guard fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path)
        else { throw ArchiveError.missingManifest }
        return written.sorted()
    }

    /// Copy an already-unpacked extension directory into place. The folder and
    /// Safari-bundle install paths both land here.
    @discardableResult
    static func copyDirectory(at source: URL, to destination: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw ArchiveError.missingManifest
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        return (fm.enumerator(at: destination, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []).sorted()
    }

    // MARK: Primitives

    /// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) — the same thing
    /// ZIP method 8 stores, with no zlib wrapper. The output size is known from
    /// the central directory, so one shot is enough; a stream would only be
    /// needed for an archive that lies about it, which is a corrupt archive.
    private static func inflate(_ data: Data, expecting size: Int) -> Data? {
        guard size > 0, !data.isEmpty else { return nil }
        var output = Data(count: size)
        let produced: Int = output.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase, size, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == size else { return nil }
        return output
    }

    /// Scan back for the end-of-central-directory signature. The comment it
    /// may be followed by is at most 65535 bytes, so 22 + that is the window.
    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let window = min(data.count, minimum + 0xFFFF)
        var offset = data.count - minimum
        let floor = data.count - window
        while offset >= floor {
            if readUInt32(data, at: offset) == 0x0605_4B50 { return offset }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
