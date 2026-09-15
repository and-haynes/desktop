//  ExtensionArchiveTests.swift
//  The ZIP reader, the CRX header, and the path checks.
//
//  The archives these read are built by `zip(1)` and Python's `zipfile` rather
//  than by anything in this project — a reader tested only against its own
//  writer proves that the two agree, not that either is right. Every entry in
//  `zen-badge.xpi` is DEFLATE-compressed, which is the branch that matters:
//  store-only would never exercise `Compression`.

import XCTest

@testable import Zen

final class ExtensionArchiveTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = ExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        ExtensionFixtures.cleanUp(scratch)
    }

    // MARK: CRX

    func testStrippingACRX3HeaderLeavesTheZIP() throws {
        let crx = try ExtensionFixtures.archive("zen-badge.crx")
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        XCTAssertFalse(ExtensionArchive.looksLikeZIP(crx), "a CRX does not start with PK")
        let stripped = try ExtensionArchive.strippingCRXHeader(crx)
        XCTAssertTrue(ExtensionArchive.looksLikeZIP(stripped))
        XCTAssertEqual(stripped, xpi, "the bytes after the header are the archive, unmodified")
    }

    func testStrippingACRX2HeaderLeavesTheZIP() throws {
        let crx = try ExtensionFixtures.archive("zen-badge-crx2.crx")
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        let stripped = try ExtensionArchive.strippingCRXHeader(crx)
        XCTAssertEqual(stripped, xpi)
    }

    func testAZIPIsLeftAloneByTheCRXStripper() throws {
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        XCTAssertEqual(try ExtensionArchive.strippingCRXHeader(xpi), xpi)
    }

    func testAnUnknownCRXVersionIsRefused() {
        var data = Data("Cr24".utf8)
        data.append(contentsOf: [9, 0, 0, 0])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try ExtensionArchive.strippingCRXHeader(data)) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .notAnArchive)
        }
    }

    func testATruncatedCRXIsRefusedRatherThanReadPastTheEnd() {
        var data = Data("Cr24".utf8)
        data.append(contentsOf: [3, 0, 0, 0])
        // A header length far past the end of the file.
        data.append(contentsOf: [0xFF, 0xFF, 0, 0])
        data.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try ExtensionArchive.strippingCRXHeader(data)) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .truncated)
        }
    }

    // MARK: Reading

    func testTheCentralDirectoryIsRead() throws {
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        let entries = try ExtensionArchive.entries(in: xpi)
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("manifest.json"))
        XCTAssertTrue(paths.contains("content.js"))
        XCTAssertTrue(paths.contains("popup.html"))
        XCTAssertTrue(
            entries.allSatisfy { $0.isDirectory || $0.compressionMethod == 8 },
            "the fixture must be DEFLATE, or the inflate path is never tested")
    }

    func testOneFileIsReadableWithoutUnpacking() throws {
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        let data = try ExtensionArchive.read(path: "manifest.json", from: xpi)
        let manifest = try ExtensionManifest.parse(data)
        XCTAssertEqual(manifest.name, "Zen Badge")
    }

    func testAManifestNestedUnderOneDirectoryIsStillFound() throws {
        let zip = try ExtensionFixtures.archive("zen-blocker-nested.zip")
        let manifest = try ExtensionManifest.parse(
            try ExtensionArchive.read(path: "manifest.json", from: zip))
        XCTAssertEqual(manifest.name, "Zen Blocker")
    }

    func testANonArchiveIsRefused() {
        let data = Data("this is a text file, not a package".utf8)
        XCTAssertFalse(ExtensionArchive.looksLikeZIP(data))
        XCTAssertThrowsError(try ExtensionArchive.entries(in: data)) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .notAnArchive)
        }
    }

    // MARK: Unpacking

    func testUnpackingAnXPIProducesTheWholeExtension() throws {
        let xpi = try ExtensionFixtures.archive("zen-badge.xpi")
        let destination = scratch.appendingPathComponent("badge")
        let written = try ExtensionArchive.unpack(xpi, to: destination)
        XCTAssertTrue(written.contains("manifest.json"))
        XCTAssertTrue(written.contains("content.js"))

        // Byte-for-byte against the directory the archive was built from —
        // inflate either reproduces the file or it does not.
        let source = try ExtensionFixtures.directory("zen-badge")
        for name in ["manifest.json", "content.js", "popup.html", "background.js"] {
            let original = try Data(contentsOf: source.appendingPathComponent(name))
            let unpacked = try Data(contentsOf: destination.appendingPathComponent(name))
            XCTAssertEqual(unpacked, original, name)
        }
    }

    func testUnpackingStripsASingleNestedRootDirectory() throws {
        let zip = try ExtensionFixtures.archive("zen-blocker-nested.zip")
        let destination = scratch.appendingPathComponent("blocker")
        try ExtensionArchive.unpack(zip, to: destination)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("manifest.json").path),
            "the archive's own `zen-blocker/` wrapper must not become a level on disk")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("rules.json").path))
    }

    func testUnpackingRefusesAnEntryThatEscapesTheDestination() throws {
        // Built here rather than checked in: a fixture whose whole purpose is
        // to contain `../../` is not something to leave lying in a repository.
        let zip = Self.storedZIP([
            ("manifest.json", Data(#"{"manifest_version":3,"name":"A","version":"1"}"#.utf8)),
            ("../../escaped.txt", Data("nope".utf8)),
        ])
        let destination = scratch.appendingPathComponent("slip")
        XCTAssertThrowsError(try ExtensionArchive.unpack(zip, to: destination)) { error in
            XCTAssertEqual(
                error as? ExtensionArchive.ArchiveError, .unsafeEntryPath("../../escaped.txt"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("escaped.txt").path),
            "the traversal must be refused before anything is written outside the destination")
    }

    func testUnpackingRefusesAnArchiveWithNoManifest() throws {
        let zip = Self.storedZIP([("readme.txt", Data("hello".utf8))])
        XCTAssertThrowsError(
            try ExtensionArchive.unpack(zip, to: scratch.appendingPathComponent("empty"))
        ) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .missingManifest)
        }
    }

    func testSigningLeftoversAreNotUnpacked() throws {
        let zip = Self.storedZIP([
            ("manifest.json", Data(#"{"manifest_version":3,"name":"A","version":"1"}"#.utf8)),
            ("META-INF/mozilla.rsa", Data([0, 1, 2])),
            ("_metadata/verified_contents.json", Data("{}".utf8)),
        ])
        let destination = scratch.appendingPathComponent("signed")
        let written = try ExtensionArchive.unpack(zip, to: destination)
        XCTAssertEqual(written, ["manifest.json"])
    }

    func testCopyingADirectoryRefusesOneWithNoManifest() throws {
        let source = scratch.appendingPathComponent("not-an-extension")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try ExtensionArchive.copyDirectory(
                at: source, to: scratch.appendingPathComponent("out"))
        ) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .missingManifest)
        }
    }

    // MARK: A minimal ZIP writer, for the cases no real packer would produce

    /// Store-only (method 0), which needs no compressor and no CRC table —
    /// the reader does not verify CRCs, because a corrupt entry fails to parse
    /// as JSON or JavaScript a moment later and WebKit re-checks everything it
    /// loads anyway.
    static func storedZIP(_ files: [(String, Data)]) -> Data {
        var output = Data()
        var directory = Data()
        var offsets: [Int] = []

        for (name, contents) in files {
            offsets.append(output.count)
            let nameBytes = Data(name.utf8)
            output.append(uint32(0x0403_4B50))
            output.append(uint16(20))  // version needed
            output.append(uint16(0))  // flags
            output.append(uint16(0))  // stored
            output.append(uint16(0))  // time
            output.append(uint16(0))  // date
            output.append(uint32(0))  // crc, unverified
            output.append(uint32(UInt32(contents.count)))
            output.append(uint32(UInt32(contents.count)))
            output.append(uint16(UInt16(nameBytes.count)))
            output.append(uint16(0))  // extra
            output.append(nameBytes)
            output.append(contents)
        }

        for (index, (name, contents)) in files.enumerated() {
            let nameBytes = Data(name.utf8)
            directory.append(uint32(0x0201_4B50))
            directory.append(uint16(20))  // version made by
            directory.append(uint16(20))  // version needed
            directory.append(uint16(0))  // flags
            directory.append(uint16(0))  // stored
            directory.append(uint16(0))  // time
            directory.append(uint16(0))  // date
            directory.append(uint32(0))  // crc
            directory.append(uint32(UInt32(contents.count)))
            directory.append(uint32(UInt32(contents.count)))
            directory.append(uint16(UInt16(nameBytes.count)))
            directory.append(uint16(0))  // extra
            directory.append(uint16(0))  // comment
            directory.append(uint16(0))  // disk
            directory.append(uint16(0))  // internal attributes
            directory.append(uint32(0))  // external attributes
            directory.append(uint32(UInt32(offsets[index])))
            directory.append(nameBytes)
        }

        let directoryOffset = output.count
        output.append(directory)
        output.append(uint32(0x0605_4B50))
        output.append(uint16(0))  // disk
        output.append(uint16(0))  // disk with central directory
        output.append(uint16(UInt16(files.count)))
        output.append(uint16(UInt16(files.count)))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(UInt32(directoryOffset)))
        output.append(uint16(0))  // comment length
        return output
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
