//  AddonsSourceTests.swift
//  Turning a pasted addons.mozilla.org address into a downloadable XPI.
//
//  Everything here is offline: `resolve` takes its fetcher as a parameter, so
//  the AMO response is a fixture literal and the test says nothing about
//  whether Mozilla's servers are up.

import XCTest

@testable import Zen

final class AddonsSourceTests: XCTestCase {

    // MARK: Slugs

    func testTheSlugIsTakenFromAfterTheAddonSegment() throws {
        let cases = [
            "https://addons.mozilla.org/en-GB/firefox/addon/ublock-origin-lite/":
                "ublock-origin-lite",
            "https://addons.mozilla.org/firefox/addon/darkreader/": "darkreader",
            "https://addons.mozilla.org/en-US/android/addon/ublock-origin/": "ublock-origin",
            "https://addons.mozilla.org/en-US/firefox/addon/darkreader/?src=search": "darkreader",
        ]
        for (input, expected) in cases {
            let url = try XCTUnwrap(URL(string: input))
            XCTAssertEqual(AddonsSource.slug(from: url), expected, input)
        }
    }

    func testAnAddonsURLWithNoAddonHasNoSlug() throws {
        let url = try XCTUnwrap(URL(string: "https://addons.mozilla.org/en-GB/firefox/"))
        XCTAssertNil(AddonsSource.slug(from: url))
    }

    func testTheAPIURLIsTheDocumentedV5Endpoint() throws {
        let url = try XCTUnwrap(AddonsSource.apiURL(slug: "darkreader"))
        XCTAssertEqual(url.host, "addons.mozilla.org")
        // `URL.path` drops a trailing slash, and AMO's endpoint has one — so
        // the whole string is what gets asserted, not the normalised path.
        XCTAssertTrue(
            url.absoluteString.contains("/api/v5/addons/addon/darkreader/"), url.absoluteString)
        XCTAssertTrue(url.query?.contains("app=firefox") == true)
    }

    // MARK: Response parsing

    func testTheV5FileURLIsFound() throws {
        let json = """
            {"slug": "darkreader", "name": {"en-US": "Dark Reader"},
             "current_version": {"version": "4.9.109",
               "file": {"url": "https://addons.mozilla.org/firefox/downloads/file/1/dr.xpi"}}}
            """
        let resolved = try XCTUnwrap(AddonsSource.downloadURL(fromAPI: Data(json.utf8)))
        XCTAssertEqual(
            resolved.url.absoluteString,
            "https://addons.mozilla.org/firefox/downloads/file/1/dr.xpi")
        XCTAssertEqual(resolved.version, "4.9.109")
        XCTAssertEqual(resolved.name, "Dark Reader")
    }

    func testTheOlderFilesArrayIsStillRead() throws {
        let json = """
            {"name": "uBO Lite", "current_version": {"version": "2.1",
             "files": [{"url": "https://addons.mozilla.org/firefox/downloads/file/2/ubol.xpi"}]}}
            """
        let resolved = try XCTUnwrap(AddonsSource.downloadURL(fromAPI: Data(json.utf8)))
        XCTAssertTrue(resolved.url.absoluteString.hasSuffix("ubol.xpi"))
        XCTAssertEqual(resolved.name, "uBO Lite")
    }

    func testAResponseWithNoFileIsNotAResolution() {
        XCTAssertNil(AddonsSource.downloadURL(fromAPI: Data(#"{"slug": "x"}"#.utf8)))
        XCTAssertNil(AddonsSource.downloadURL(fromAPI: Data("not json".utf8)))
    }

    // MARK: Resolution

    func testAListingResolvesThroughTheAPI() async throws {
        let json = """
            {"name": {"en-US": "uBlock Origin Lite"},
             "current_version": {"version": "2.1.6",
               "file": {"url": "https://addons.mozilla.org/firefox/downloads/file/9/ubol.xpi"}}}
            """
        var requested: [URL] = []
        let resolution = try await AddonsSource.resolve(
            input: "https://addons.mozilla.org/en-GB/firefox/addon/ublock-origin-lite/"
        ) { url in
            requested.append(url)
            return (Data(json.utf8), HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(requested.count, 1)
        XCTAssertTrue(requested[0].absoluteString.contains("/addon/ublock-origin-lite/"))
        XCTAssertTrue(resolution.downloadURL.absoluteString.hasSuffix("ubol.xpi"))
        XCTAssertEqual(resolution.displayName, "uBlock Origin Lite")
        XCTAssertEqual(resolution.version, "2.1.6")
        guard case .addons(_, let slug) = resolution.source else {
            return XCTFail("the listing must be remembered so the extension can be updated")
        }
        XCTAssertEqual(slug, "ublock-origin-lite")
    }

    func testADirectPackageURLNeedsNoAPICall() async throws {
        var called = false
        let resolution = try await AddonsSource.resolve(
            input: "https://example.com/build/thing.crx"
        ) { url in
            called = true
            return (Data(), HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertFalse(called)
        XCTAssertEqual(resolution.downloadURL.absoluteString, "https://example.com/build/thing.crx")
        XCTAssertEqual(resolution.source, .file(name: "thing.crx"))
    }

    func testABareHostIsGivenAScheme() async throws {
        let resolution = try await AddonsSource.resolve(input: "example.com/a.xpi") { url in
            (Data(), HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(resolution.downloadURL.scheme, "https")
    }

    func testAnUnrelatedSiteIsRefusedWithAnExplanation() async {
        do {
            _ = try await AddonsSource.resolve(input: "https://chromewebstore.google.com/x") { url in
                (Data(), HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("expected a refusal")
        } catch let error as AddonsSource.ResolveError {
            XCTAssertEqual(error, .notAddons(host: "chromewebstore.google.com"))
            XCTAssertTrue(
                error.errorDescription?.contains(".xpi") == true,
                "the message has to say what would work instead")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnHTTPErrorIsReportedWithItsStatus() async {
        do {
            _ = try await AddonsSource.resolve(
                input: "https://addons.mozilla.org/firefox/addon/nope/"
            ) { url in
                (Data(), HTTPURLResponse(
                    url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("expected a refusal")
        } catch let error as AddonsSource.ResolveError {
            XCTAssertEqual(error, .httpStatus(404))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
