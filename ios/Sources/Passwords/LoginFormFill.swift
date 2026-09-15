//  LoginFormFill.swift
//  Finding a login form in a page and putting a credential into it (#008AD).
//
//  Three scripts, and the reason they are strings in a Swift file rather than a
//  `.js` resource is that two of them take parameters that must be escaped
//  exactly once, at the only place that knows what they are.
//
//  ## The heuristics, and why they are Bitwarden's
//
//  There is no standard for "this is the login form". `autocomplete="username"`
//  and `autocomplete="current-password"` are the standard and perhaps a third
//  of real sites set them. So the rules below are the ones the browser
//  extensions converged on after years of bug reports, and they are worth
//  copying rather than re-deriving:
//
//   - The **password** field is the anchor. `input[type=password]`, visible,
//     not disabled, not readonly. Everything else is found relative to it.
//   - The **username** field is the nearest *preceding* text-ish input in the
//     same form — preceding, because "new password / confirm password" screens
//     put a text field after the password and filling it would be wrong.
//   - Names, ids, placeholders and labels are scored, not matched: `user`,
//     `email`, `login`, `account` score up; `search`, `captcha`, `otp`,
//     `phone`, `zip` score down. A score, not a first-match, because a page
//     with both a search box and a login form will otherwise fill the search
//     box on about a third of sites.
//   - A form with **two or more** password fields is a registration or
//     change-password form. Fill the first one only, and do not offer to save
//     from it on submit, because the "password" there is a *new* password that
//     has not been accepted yet.
//
//  ## Setting a value that React believes
//
//  `element.value = x` updates the DOM and does nothing else. A React-
//  controlled input keeps its own state, sees no event, and reverts the moment
//  anything re-renders — the field looks filled and submits empty, which is the
//  single most common "the password manager is broken" report. The fix is to
//  call the *native* value setter off the prototype, bypassing React's own
//  property override, and then dispatch `input` and `change` with `bubbles:
//  true`. That is what the extensions do and it is not optional.
//
//  ## The one user script, and #008AB
//
//  On the `ios` branch it is an asserted invariant that Zen injects **nothing**
//  into page content, because a script that rewrites forms is one of the ways
//  iOS Password AutoFill goes quiet. This branch adds exactly one, and it is
//  written to keep that promise: `submitObserverScript` only *listens* — a
//  capturing `submit` listener and a click listener — and never touches a
//  field, a name, an attribute or the focus. Nothing about the form changes, so
//  there is nothing for AutoFill to fail to recognise. `PasswordsAutoFillTests`
//  checks that the two features still coexist rather than taking it on trust.

import Foundation

enum LoginFormFill {

    /// The message handler name the submit observer posts to.
    static let submitMessageHandler = "zenLoginSubmit"

    // MARK: - Shared helpers

    /// The scoring and field-finding half, shared by all three scripts so the
    /// "which field is the username" answer cannot drift between detecting,
    /// filling and saving. Evaluated inside an IIFE so nothing lands on
    /// `window`.
    private static let helpers = """
        const SCORE_UP = ['username','user','email','e-mail','login','account','identifier','userid','user_id','loginid'];
        const SCORE_DOWN = ['search','query','captcha','otp','code','token','phone','tel','zip','postal','card','cvv','coupon','promo','comment','address','firstname','lastname','company'];

        function visible(el) {
          if (!el) return false;
          if (el.disabled || el.readOnly) return false;
          if (el.type === 'hidden') return false;
          const style = window.getComputedStyle(el);
          if (style.visibility === 'hidden' || style.display === 'none') return false;
          if (parseFloat(style.opacity || '1') === 0) return false;
          const rect = el.getBoundingClientRect();
          // A zero-sized field is either off-screen scaffolding or a honeypot;
          // either way it is not the one a person is looking at.
          return rect.width > 0 && rect.height > 0;
        }

        function haystack(el) {
          const label = el.labels && el.labels.length ? el.labels[0].textContent : '';
          return [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
                  el.getAttribute('autocomplete'), label]
            .filter(Boolean).join(' ').toLowerCase();
        }

        function score(el) {
          const text = haystack(el);
          let value = 0;
          // The declared answer, when a site bothers to declare one, outweighs
          // every guess below it.
          const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
          if (auto === 'username' || auto === 'email') value += 100;
          if (el.type === 'email') value += 20;
          for (const term of SCORE_UP) if (text.includes(term)) value += 10;
          for (const term of SCORE_DOWN) if (text.includes(term)) value -= 25;
          return value;
        }

        function passwordFields(root) {
          return Array.from(root.querySelectorAll('input[type=password]')).filter(visible);
        }

        /// The password field to act on, plus its form and sibling count.
        function primaryPassword() {
          let fields = passwordFields(document);
          if (!fields.length) return null;
          // Prefer the one the caret is in, so a page with a login form and a
          // change-password form fills the one being used.
          const active = document.activeElement;
          const focused = fields.find((f) => f === active);
          const field = focused || fields[0];
          const form = field.form || field.closest('form') || document.body;
          const inForm = passwordFields(form);
          return { field: field, form: form, passwordCount: inForm.length || fields.length };
        }

        function usernameFor(password, form) {
          const candidates = Array.from(
            form.querySelectorAll('input[type=text], input[type=email], input[type=tel], input:not([type])')
          ).filter(visible);
          if (!candidates.length) return null;
          // Only fields *before* the password: "new password / confirm" pages
          // put unrelated text inputs after it.
          const order = Array.from(form.querySelectorAll('input'));
          const passwordIndex = order.indexOf(password);
          const preceding = candidates.filter((el) => order.indexOf(el) < passwordIndex);
          const pool = preceding.length ? preceding : candidates;
          let best = null;
          let bestScore = -Infinity;
          for (const el of pool) {
            const value = score(el);
            // Ties go to the field nearest the password, which is what the
            // reverse iteration below achieves.
            if (value >= bestScore) { bestScore = value; best = el; }
          }
          // A field that scores negative is one we actively believe is wrong —
          // a search box. Better to fill only the password than the wrong box.
          return bestScore < 0 ? null : best;
        }

        function setValue(el, value) {
          // Bypass React's property override; see the file comment.
          const proto = el instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) { setter.set.call(el, value); } else { el.value = value; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        """

    // MARK: - Detect

    /// Does this page have a login form worth offering the panel for?
    ///
    /// Returns a small JSON object rather than a boolean: the panel wants to
    /// know whether filling is possible, and the save prompt wants to know
    /// whether the form was a *sign-in* or a *sign-up*, and both answers come
    /// from the same walk of the DOM.
    static let detectScript = """
        (function () {
          \(helpers)
          const found = primaryPassword();
          if (!found) return JSON.stringify({ hasLoginForm: false });
          const username = usernameFor(found.field, found.form);
          return JSON.stringify({
            hasLoginForm: true,
            hasUsernameField: !!username,
            passwordCount: found.passwordCount,
            isLikelyRegistration: found.passwordCount > 1
          });
        })();
        """

    // MARK: - Fill

    /// Fill the page's login form.
    ///
    /// The username is optional because plenty of vault entries have only a
    /// password, and a two-step sign-in (Google, Microsoft) shows the password
    /// field on a page that no longer has a username field at all.
    static func fillScript(username: String?, password: String) -> String {
        """
        (function () {
          \(helpers)
          const USERNAME = \(jsStringLiteral(username));
          const PASSWORD = \(jsStringLiteral(password));
          const found = primaryPassword();
          if (!found) return JSON.stringify({ filled: false, reason: 'no password field' });
          setValue(found.field, PASSWORD);
          let filledUsername = false;
          if (USERNAME !== null) {
            const username = usernameFor(found.field, found.form);
            if (username) { setValue(username, USERNAME); filledUsername = true; }
          }
          // Focus the password so the keyboard's Go key submits, and so it is
          // visibly the field that was touched.
          try { found.field.focus(); } catch (e) {}
          return JSON.stringify({
            filled: true,
            filledUsername: filledUsername,
            passwordCount: found.passwordCount
          });
        })();
        """
    }

    // MARK: - Observe submissions

    /// A passive listener that reports a submitted credential so the save
    /// prompt can offer to store it.
    ///
    /// Capturing listeners on `document`, because a site that calls
    /// `preventDefault` and submits over `fetch` never fires a bubbling submit
    /// on anything we could attach to afterwards. The click listener catches
    /// the large family of login forms that are not `<form>`s at all.
    ///
    /// It reads values and posts them; it writes nothing. See the file comment
    /// on why that matters for #008AB.
    static let submitObserverScript = """
        (function () {
          if (window.__zenLoginObserver) return;
          window.__zenLoginObserver = true;
          \(helpers)

          function report(trigger) {
            const found = primaryPassword();
            if (!found) return;
            const password = found.field.value;
            if (!password) return;
            const usernameField = usernameFor(found.field, found.form);
            try {
              window.webkit.messageHandlers.\(submitMessageHandler).postMessage({
                username: usernameField ? usernameField.value : null,
                password: password,
                url: window.location.href,
                title: document.title || window.location.hostname,
                isLikelyRegistration: found.passwordCount > 1,
                trigger: trigger
              });
            } catch (e) {}
          }

          document.addEventListener('submit', function () { report('submit'); }, true);
          document.addEventListener('click', function (event) {
            const target = event.target;
            if (!target || !target.closest) return;
            const button = target.closest('button, input[type=submit], [role=button]');
            if (!button) return;
            // A button that is not a submit button may still be the sign-in
            // button; reporting is harmless because the prompt only appears
            // once a password field actually has content.
            report('click');
          }, true);
        })();
        """

    // MARK: - Escaping

    /// A JavaScript string literal, or the token `null`.
    ///
    /// `JSONSerialization` rather than hand-rolled escaping: a password is
    /// arbitrary text, and quotes, backslashes, newlines and U+2028 in it have
    /// all been somebody's injection bug. JSON string syntax is a subset of
    /// JavaScript string syntax, so a JSON-encoded string is a valid JS
    /// literal — except for U+2028/U+2029, which JSON allows raw and JS treats
    /// as line terminators, so those are escaped afterwards.
    static func jsStringLiteral(_ value: String?) -> String {
        guard let value else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
            let array = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        // `["…"]` → `"…"`.
        let literal = String(array.dropFirst().dropLast())
        return
            literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

// MARK: - Results

/// What `detectScript` reports.
struct LoginFormDetection: Codable, Equatable, Sendable {
    var hasLoginForm: Bool
    var hasUsernameField: Bool?
    var passwordCount: Int?
    var isLikelyRegistration: Bool?

    static let none = LoginFormDetection(hasLoginForm: false)
}

/// What `fillScript` reports.
struct LoginFormFillResult: Codable, Equatable, Sendable {
    var filled: Bool
    var filledUsername: Bool?
    var reason: String?
    var passwordCount: Int?
}

/// What the submit observer posts.
///
/// `Identifiable` so it can drive `.sheet(item:)`: the save prompt is built
/// *from* the credential, and a presentation bound to a bool would have to cope
/// with a nil one.
struct SubmittedCredential: Equatable, Sendable, Identifiable {
    let id = UUID()
    var username: String?
    var password: String
    var url: URL
    var title: String
    var isLikelyRegistration: Bool

    /// Built from the message body, which is `Any` and arrives from a web page,
    /// so every field is checked rather than force-cast.
    init?(messageBody: Any) {
        guard let dictionary = messageBody as? [String: Any],
            let password = dictionary["password"] as? String, !password.isEmpty,
            let urlString = dictionary["url"] as? String,
            let url = URL(string: urlString)
        else { return nil }
        self.password = password
        self.url = url
        self.username = (dictionary["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.title = (dictionary["title"] as? String) ?? url.host ?? "Login"
        self.isLikelyRegistration = (dictionary["isLikelyRegistration"] as? Bool) ?? false
    }
}
