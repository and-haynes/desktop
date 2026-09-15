//  ZenApp.swift
//  Zen for iOS — Zen Browser's UX on WebKit.
//
//  Desktop Zen is a Firefox fork, so it renders with Gecko. Neither half of
//  that travels to iOS: Apple requires browsers outside the EU to use WebKit,
//  and Gecko has no iOS build target at all. What *is* portable is the part
//  people actually choose Zen for — spaces, vertical tabs, essentials, glance,
//  split view, compact mode — so that is what this app rebuilds, natively, on
//  WKWebView.

import SwiftUI

@main
struct ZenApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
