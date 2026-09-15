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

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        @objc func editingChanged(_ field: UITextField) {
            text = field.text ?? ""
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
