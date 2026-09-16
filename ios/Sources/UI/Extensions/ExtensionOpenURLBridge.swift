//  ExtensionOpenURLBridge.swift
//  Answering the Share sheet (#008B8).
//
//  `Info.plist` declares the XPI and CRX types, so Zen appears in the Share
//  sheet and in Files' "Open With" for an extension downloaded in Safari. This
//  is the other half: without something answering `onOpenURL`, choosing Zen
//  launches it and nothing happens, which is a worse outcome than not offering
//  the app at all.
//
//  It lands on the same install sheet as every other route — read the package,
//  scan it, show what it wants and what WebKit will ignore, and install only if
//  somebody says so. The file is never installed on arrival: the whole point of
//  the two-step install is that a package arriving from outside the app is
//  exactly the case where "install, then ask" is unacceptable.
//
//  A separate `ViewModifier` because `RootView`'s own modifier chain is already
//  at the type checker's limit — the same reason `ExtensionBridge` and
//  `CompactBarBridge` are layers rather than lines.

import SwiftUI

struct ExtensionOpenURLBridge: ViewModifier {
    @ObservedObject var state: BrowserState
    @ObservedObject var host: ExtensionHost
    let palette: ZenPalette

    @Environment(\.scenePhase) private var scenePhase

    @State private var prepared: PreparedExtension?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in receive(url) }
            // A crash between the hand-over and the install leaves the system's
            // copy in `Documents/Inbox` and nothing ever comes back for it.
            // Clearing on the way out rather than at launch, because a cold
            // launch *from* the Share sheet is a launch with a file in there
            // that has not been handed over yet.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                ExtensionInbox.clearInbox()
            }
            .sheet(item: $prepared) { candidate in
                ExtensionInstallSheet(prepared: candidate, host: host)
                    .environment(\.zenPalette, palette)
            }
            .alert(
                "Could not read that", isPresented: .constant(failure != nil), presenting: failure
            ) { _ in
                Button("OK") { failure = nil }
            } message: { message in
                Text(message)
            }
    }

    private func receive(_ url: URL) {
        // Anything that is not a package is somebody else's business — Zen
        // claims no other document type, so this is a defensive branch rather
        // than a user-facing path.
        guard url.isFileURL else { return }

        // SwiftUI presents one sheet at a time, and a presentation requested
        // while another is still on screen is dropped silently. Settings is the
        // realistic collision (its own Extensions screen has an "Install from
        // Files" button), so put it away first and let it finish leaving.
        let wasCovered = state.isSettingsPresented || state.isHistorySheetPresented
        state.isSettingsPresented = false
        state.isHistorySheetPresented = false

        Task {
            if wasCovered { try? await Task.sleep(for: .milliseconds(800)) }
            do {
                prepared = try ExtensionInbox.prepare(url, in: host.store)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
