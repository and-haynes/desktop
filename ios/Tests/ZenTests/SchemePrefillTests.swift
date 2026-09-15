//  SchemePrefillTests.swift
//  A URL bar that rewrites what you typed is infuriating the first time it is
//  wrong, so the trigger rules are narrow and every one of them is pinned here
//  (#0089B).

import SwiftUI
import UIKit
import XCTest

@testable import Zen

final class SchemePrefillTests: XCTestCase {

    private func typed(_ text: String, caret: Int? = nil, removed: Bool = false)
        -> SchemePrefill.Edit?
    {
        SchemePrefill.edit(
            text: text, caret: caret ?? text.count, isPaste: false, userRemovedScheme: removed)
    }

    // MARK: It fires

    func testEachPrivateOctetTriggers() {
        for prefix in ["10.", "192.", "172."] {
            XCTAssertEqual(
                typed(prefix), SchemePrefill.Edit(text: "https://\(prefix)", caret: 8 + prefix.count),
                prefix)
        }
    }

    /// The point of the whole feature: the caret ends up exactly where the
    /// user's own typing left it, so the next digit lands in the right place.
    func testTheCaretStaysAfterWhatWasTyped() {
        let edit = typed("10.")
        XCTAssertEqual(edit?.text, "https://10.")
        XCTAssertEqual(edit?.caret, 11)
        // Which is the end of the string — the user types on from there.
        XCTAssertEqual(edit?.caret, edit?.text.count)
    }

    // MARK: It does not fire

    func testAnExistingSchemeIsLeftAlone() {
        XCTAssertNil(typed("http://10."))
        XCTAssertNil(typed("https://10."))
        XCTAssertNil(typed("HTTPS://10."))
    }

    func testAPasteIsNeverRewritten() {
        XCTAssertNil(
            SchemePrefill.edit(text: "10.", caret: 3, isPaste: true, userRemovedScheme: false))
    }

    /// Saying no to an autocomplete has to mean no, not "ask again next
    /// keystroke".
    func testItDoesNotComeBackAfterBeingDeleted() {
        XCTAssertNil(typed("10.", removed: true))
    }

    func testAPartialOctetDoesNotTrigger() {
        XCTAssertNil(typed("1"))
        XCTAssertNil(typed("10"))
        XCTAssertNil(typed("19"))
        XCTAssertNil(typed("192"))
    }

    /// Only the whole field. "9.10." is a version number and "ratio 10." is a
    /// search; neither is an address.
    func testTheTriggerMustBeTheWholeField() {
        XCTAssertNil(typed("9.10."))
        XCTAssertNil(typed("ratio 10."))
        XCTAssertNil(typed("10.0"), "past the trigger, the user is already typing an address")
        XCTAssertNil(typed("x10."))
    }

    /// A caret parked mid-string is someone editing, not someone starting an
    /// address.
    func testACaretInTheMiddleDoesNotTrigger() {
        XCTAssertNil(typed("10.", caret: 1))
        XCTAssertNil(typed("10.", caret: 0))
    }

    func testOtherLeadingOctetsAreNotTriggers() {
        for text in ["11.", "1.", "127.", "169.", "8.", "172", "193."] {
            XCTAssertNil(typed(text), text)
        }
    }

    // MARK: The removal latch

    func testDeletingAnInsertedSchemeIsDetected() {
        XCTAssertTrue(SchemePrefill.removesScheme(previous: "https://10.", updated: "https:/10."))
        XCTAssertTrue(SchemePrefill.removesScheme(previous: "https://10.", updated: "10."))
        XCTAssertTrue(SchemePrefill.removesScheme(previous: "https://", updated: "https:/"))
    }

    func testTypingOnAfterAnInsertIsNotARemoval() {
        XCTAssertFalse(
            SchemePrefill.removesScheme(previous: "https://10.", updated: "https://10.0"))
        XCTAssertFalse(
            SchemePrefill.removesScheme(previous: "https://10.0", updated: "https://10."))
    }

    func testARemovalIsNotClaimedWhenThereWasNoScheme() {
        XCTAssertFalse(SchemePrefill.removesScheme(previous: "10.", updated: "10"))
        XCTAssertFalse(SchemePrefill.removesScheme(previous: "", updated: "1"))
    }

    // MARK: What it produces actually navigates

    /// The insert is only worth anything if the result resolves as a URL —
    /// otherwise we have rewritten the field for nothing.
    func testTheResultResolvesAsAnAddress() {
        let edit = typed("10.")
        let typedOn = (edit?.text ?? "") + "0.0.80:8006"
        switch URLDetector.intent(for: typedOn, engine: .duckduckgo) {
        case .navigate(let url):
            XCTAssertEqual(url.absoluteString, "https://10.0.0.80:8006")
        case .search:
            XCTFail("an address with a scheme must navigate")
        }
    }
}

/// The pure rules above are only half of it — the other half is the live
/// `UITextField` path, which is where the first two attempts at this went
/// wrong. Driving a real field and a real coordinator is the only way to catch
/// that.
@MainActor
final class SchemePrefillFieldTests: XCTestCase {

    private func makeField() -> (UITextField, OmniboxTextField.Coordinator, Box) {
        let box = Box()
        let coordinator = OmniboxTextField.Coordinator(
            text: Binding(get: { box.text }, set: { box.text = $0 }), onSubmit: {})
        let field = UITextField()
        field.delegate = coordinator
        field.addTarget(
            coordinator, action: #selector(OmniboxTextField.Coordinator.editingChanged(_:)),
            for: .editingChanged)
        coordinator.textFieldDidBeginEditing(field)
        return (field, coordinator, box)
    }

    final class Box { var text = "" }

    /// Type one character, the way a finger does.
    private func type(_ character: String, into field: UITextField,
                      _ coordinator: OmniboxTextField.Coordinator) {
        field.text = (field.text ?? "") + character
        if let end = field.position(from: field.beginningOfDocument, offset: field.text?.count ?? 0)
        {
            field.selectedTextRange = field.textRange(from: end, to: end)
        }
        coordinator.editingChanged(field)
    }

    func testTypingTheOctetFillsTheSchemeIntoTheField() {
        let (field, coordinator, box) = makeField()
        for character in "10." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "https://10.")
        XCTAssertEqual(box.text, "https://10.")
    }

    func testTypingOnAfterTheInsertAppendsWhereExpected() {
        let (field, coordinator, box) = makeField()
        for character in "10.0.0.80" { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "https://10.0.0.80")
        XCTAssertEqual(box.text, "https://10.0.0.80")
    }

    func testDeletingTheSchemeStopsItComingBack() {
        let (field, coordinator, box) = makeField()
        for character in "10." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "https://10.")

        // Clear the field the way a long backspace does.
        field.text = ""
        coordinator.editingChanged(field)
        for character in "10." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "10.", "the scheme must not be re-inserted in the same edit")
        XCTAssertEqual(box.text, "10.")
    }

    /// A whole string arriving at once is a paste, and a paste is left alone.
    func testAPastedOctetIsLeftAlone() {
        let (field, coordinator, box) = makeField()
        field.text = "10."
        coordinator.editingChanged(field)
        XCTAssertEqual(field.text, "10.")
        XCTAssertEqual(box.text, "10.")
    }

    /// The omnibox opens prefilled with the current URL, which is usually
    /// `https://…`. Selecting all and typing over it looks exactly like
    /// deleting an inserted scheme — and treating it as one armed the opt-out
    /// on the first keystroke of every edit, which stopped the feature working
    /// at all.
    func testTypingOverAPrefilledURLDoesNotCountAsARefusal() {
        let (field, coordinator, _) = makeField()
        field.text = "https://example.com"
        coordinator.textFieldDidBeginEditing(field)
        // Select-all then type: the whole value is replaced by one character.
        field.text = "1"
        coordinator.editingChanged(field)
        for character in "0." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "https://10.")
    }

    /// A new edit forgets the refusal.
    func testANewEditAsksAgain() {
        let (field, coordinator, _) = makeField()
        for character in "10." { type(String(character), into: field, coordinator) }
        field.text = ""
        coordinator.editingChanged(field)
        for character in "10." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "10.")

        field.text = ""
        coordinator.textFieldDidBeginEditing(field)
        for character in "10." { type(String(character), into: field, coordinator) }
        XCTAssertEqual(field.text, "https://10.")
    }
}
