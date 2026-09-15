//  ExtensionInstallSheet.swift
//  What an extension wants, and what it will not get — before it is installed.
//
//  This is the whole reason installing is two steps. The package has been
//  unpacked into a staging directory and read, and nothing has been loaded:
//  cancelling here deletes the bytes and leaves no record. So there is room to
//  show the permissions, the host access and the compatibility report, and to
//  let each line be turned off, before anything runs.
//
//  A permission turned off is *denied*, not merely un-granted, and the two
//  differ: a denied permission is one WebKit will not ask about again, while an
//  un-granted one leaves the extension free to ask at runtime. Since Zen
//  answers runtime prompts from this screen's decisions rather than by
//  interrupting the page, "off" has to mean denied or the question would never
//  be asked at all.

import SwiftUI

struct ExtensionInstallSheet: View {
    let prepared: PreparedExtension
    @ObservedObject var host: ExtensionHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var grantedPermissions: Set<String> = []
    @State private var grantedHosts: Set<String> = []
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                if !allPermissions.isEmpty { permissionsSection }
                if !allHosts.isEmpty { hostsSection }
                ExtensionCompatibilityView(report: prepared.record.compatibility)
                sourceSection
            }
            .navigationTitle(prepared.isUpdate ? "Update Extension" : "Install Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        host.store.discard(prepared)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prepared.isUpdate ? "Update" : "Install") { install() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("installExtensionButton")
                }
            }
            .alert(
                "Could not install", isPresented: .constant(failure != nil),
                presenting: failure
            ) { _ in
                Button("OK") { failure = nil }
            } message: { message in
                Text(message)
            }
            .onAppear(perform: seedGrants)
        }
        .tint(palette.accent.color)
        .accessibilityIdentifier("extensionInstallSheet")
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                ExtensionIconView(
                    record: prepared.record, size: 44, directory: prepared.packageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prepared.record.name).font(.headline)
                    Text("Version \(prepared.record.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = prepared.record.descriptionText, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if prepared.isUpdate {
                Label(
                    "Replaces the copy already installed, keeping what you allowed.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(allPermissions, id: \.self) { permission in
                Toggle(isOn: binding(for: permission, in: $grantedPermissions)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ExtensionPermissionCopy.title(permission))
                        Text(ExtensionPermissionCopy.detail(permission))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("grantPermission-\(permission)")
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text(
                "Turning one off denies it. Zen answers an extension's later requests from "
                    + "these switches rather than interrupting a page, so a permission you "
                    + "decline stays declined until you change it here or in Settings.")
        }
    }

    private var hostsSection: some View {
        Section {
            ForEach(allHosts, id: \.self) { pattern in
                Toggle(isOn: binding(for: pattern, in: $grantedHosts)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(InstalledExtension.hostLabel(pattern) ?? "Every site")
                        Text(pattern)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("grantHost-\(pattern)")
            }
        } header: {
            Text("Site access")
        } footer: {
            Text(
                "Host access is what lets an extension read and change the pages you visit. "
                    + "Content blockers need it everywhere; most other things do not. You can "
                    + "also allow or refuse one site at a time afterwards.")
        }
    }

    private var sourceSection: some View {
        Section {
            LabeledContent("Source", value: prepared.record.source.displayName)
            LabeledContent("Manifest", value: "v\(prepared.record.manifestVersion)")
        } footer: {
            Text(
                "Nothing has been installed yet. Cancelling deletes the unpacked copy and "
                    + "leaves no record of it.")
        }
    }

    // MARK: Behaviour

    /// Default the switches on — an extension that is installed and then
    /// granted nothing is an extension that does not work, and "install with
    /// everything it asked for" is the choice somebody is making by tapping
    /// Install. The switches exist so the choice can be narrowed, not so it has
    /// to be assembled from nothing.
    private func seedGrants() {
        guard grantedPermissions.isEmpty, grantedHosts.isEmpty else { return }
        if prepared.isUpdate {
            grantedPermissions = Set(prepared.record.grantedPermissions)
            grantedHosts = Set(prepared.record.grantedHostPatterns)
            return
        }
        grantedPermissions = Set(prepared.record.requestedPermissions)
        grantedHosts = Set(prepared.record.requestedHostPatterns)
    }

    private var allPermissions: [String] {
        (prepared.record.requestedPermissions + prepared.record.optionalPermissions)
            .uniqued().sorted()
    }

    private var allHosts: [String] {
        (prepared.record.requestedHostPatterns + prepared.record.optionalHostPatterns)
            .uniqued().sorted()
    }

    private func binding(for key: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(key) },
            set: { on in
                if on { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) }
            })
    }

    private func install() {
        do {
            _ = try host.store.commit(
                prepared, grantedPermissions: grantedPermissions,
                grantedHostPatterns: grantedHosts)
            host.installedChanged()
            Haptics.shared.fire(.bookmarkAdd)
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Plain-language names for the permissions a manifest can ask for.
///
/// The raw strings are developer-facing (`declarativeNetRequestWithHostAccess`
/// is not a sentence), and a permission dialog that shows them is a dialog
/// nobody reads. Anything not in the table falls back to the raw name rather
/// than to a guess.
enum ExtensionPermissionCopy {
    private static let copy: [String: (String, String)] = [
        "activeTab": (
            "The page you are on",
            "Read and change the current page, but only after you tap this extension's button."
        ),
        "alarms": ("Timers", "Run work on a schedule in the background."),
        "clipboardWrite": ("Write to the clipboard", "Put text on the clipboard."),
        "contextMenus": ("Long-press menu", "Add its own items to the page's long-press menu."),
        "menus": ("Long-press menu", "Add its own items to the page's long-press menu."),
        "cookies": ("Cookies", "Read and change cookies for the sites it has access to."),
        "declarativeNetRequest": (
            "Block and change requests",
            "Block or rewrite requests using rules it ships. Zen never sees which requests — "
                + "WebKit applies the rules itself."
        ),
        "declarativeNetRequestFeedback": (
            "Report what it blocked", "Tell the extension which of its own rules matched."
        ),
        "declarativeNetRequestWithHostAccess": (
            "Block and change requests", "As above, on the sites you have granted."
        ),
        "nativeMessaging": (
            "Talk to a companion app",
            "Exchange messages with a native app. Zen ships no companion app, so this does "
                + "nothing here."
        ),
        "scripting": ("Run scripts in pages", "Inject scripts into the sites it has access to."),
        "storage": ("Its own storage", "Keep settings and data of its own, per space."),
        "tabs": ("Your tabs", "See the addresses and titles of every tab, and open or close them."),
        "unlimitedStorage": ("Unlimited storage", "Store more than the usual quota."),
        "webNavigation": ("Navigation events", "Be told when pages start and finish loading."),
        "webRequest": (
            "Watch requests",
            "Observe the requests pages make. WebKit does not let an extension cancel or "
                + "rewrite them this way."
        ),
        "webRequestBlocking": (
            "Block requests (unsupported)",
            "Firefox's blocking request API. WebKit does not implement it, so granting this "
                + "achieves nothing."
        ),
    ]

    static func title(_ permission: String) -> String {
        copy[permission]?.0 ?? permission
    }

    static func detail(_ permission: String) -> String {
        copy[permission]?.1
            ?? "The extension asked for `\(permission)`. WebKit does not recognise it, so it "
                + "grants nothing."
    }
}

extension Array where Element: Hashable {
    /// Order-preserving deduplication.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
