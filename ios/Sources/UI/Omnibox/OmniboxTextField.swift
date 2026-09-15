//  OmniboxTextField.swift
//  A UITextField wrapper for the address bar.
//
//  SwiftUI's TextField cannot select its contents on focus, and an address bar
//  that does not is actively wrong: you tap it to go somewhere new, type "hn",
//  and end up at `https://example.com/hn` because your text was appended to the
//  URL already sitting there. Every browser selects-all on focus; so do we.
//
//  Wrapping UITextField also gets us the Go key and the web-search keyboard
//  without fighting SwiftUI for them.

import SwiftUI
import UIKit

struct OmniboxTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: UIColor
    var tintColor: UIColor
    /// Set true to take focus; the field selects everything when it does.
    var isFocused: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.clearButtonMode = .never
        field.font = .systemFont(ofSize: 17)
        field.accessibilityIdentifier = "omniboxField"
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        // Only write back when the model genuinely diverged, or we would fight
        // the user's cursor on every keystroke.
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.textColor = textColor
        field.tintColor = tintColor

        if isFocused && !field.isFirstResponder {
            DispatchQueue.main.async {
                guard field.window != nil else { return }
                field.becomeFirstResponder()
                // Select rather than place a caret at the end: typing should
                // replace the current URL, not extend it.
                field.selectAll(nil)
            }
        } else if !isFocused && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        /// Latched when the user deletes a scheme this field inserted, so it is
        /// not helpfully re-added on the very next keystroke.
        private var userRemovedScheme = false
        /// The field's contents before the current change — the target action
        /// gets no range, so this is how we tell one typed character from a
        /// pasted string.
        private var lastValue = ""
        /// True while the field holds a scheme this code put there. Only then
        /// does deleting one count as a refusal.
        private var insertedScheme = false

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        /// Every accepted change comes through here, including the scheme
        /// prefill (#0089B).
        ///
        /// Deliberately *not* `shouldChangeCharactersIn`, which looks like the
        /// natural home for it: that method is not called for every path text
        /// reaches a `UITextField` by, and the ones it misses are exactly the
        /// synthetic ones. `editingChanged` is the target action — it fires
        /// whatever moved the text — so the before/after comparison happens
        /// here instead, with `lastValue` standing in for the range the
        /// delegate would have handed us.
        @objc func editingChanged(_ field: UITextField) {
            let updated = field.text ?? ""

            // Deleting a scheme *we* inserted is a "no". Latch it for the rest
            // of this edit rather than putting it straight back.
            //
            // The `insertedScheme` guard is load-bearing, and its absence was a
            // real bug: the omnibox opens prefilled with the current URL, which
            // is usually `https://…`, and selecting all and typing over it
            // looks exactly like deleting a scheme. Without the guard the
            // feature armed its own opt-out on the very first keystroke of
            // every edit and never fired at all.
            if insertedScheme,
                SchemePrefill.removesScheme(previous: lastValue, updated: updated)
            {
                userRemovedScheme = true
                insertedScheme = false
                lastValue = updated
                text = updated
                return
            }

            // More than one new character at once is a paste (or a dictation
            // insert): a decision someone already made, which we do not touch.
            let inserted = updated.count - lastValue.count
            let caret =
                field.selectedTextRange
                .map { field.offset(from: field.beginningOfDocument, to: $0.end) }
                ?? updated.count

            guard
                let edit = SchemePrefill.edit(
                    text: updated, caret: caret, isPaste: inserted > 1,
                    userRemovedScheme: userRemovedScheme)
            else {
                lastValue = updated
                text = updated
                return
            }

            field.text = edit.text
            // The caret goes back exactly where the user's own typing left it,
            // so the next character lands where they expect.
            if let position = field.position(from: field.beginningOfDocument, offset: edit.caret) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
            insertedScheme = true
            lastValue = edit.text
            text = edit.text
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            // A fresh edit gets a fresh answer to the question.
            userRemovedScheme = false
            insertedScheme = false
            lastValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            // Push the final value through before committing: the last
            // keystroke and Return can land in the same runloop turn.
            text = field.text ?? ""
            onSubmit()
            return true
        }
    }
}
