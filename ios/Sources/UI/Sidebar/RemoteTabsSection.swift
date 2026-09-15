//  RemoteTabsSection.swift
//  "From your other devices" — the bottom of the sidebar.
//
//  Zen's desktop sidebar shows the account's other devices and what they have
//  open. This is the same idea with a phone's constraints: collapsed by
//  default so it never pushes this device's own tabs off the screen, one
//  disclosure per device, and a tap opens the page here rather than adopting
//  the tab — it belongs to the other machine, and it stays there.

import SwiftUI

struct RemoteTabsSection: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var sync: SyncService
    @Environment(\.zenPalette) private var palette
    @State private var expanded: Set<String> = []

    var body: some View {
        if !sync.remoteTabs.isEmpty {
            VStack(alignment: .leading, spacing: ZenMetrics.rowSpacing) {
                Text("Other devices")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.text.withAlpha(0.45).color)
                    .padding(.top, 10)
                    .padding(.horizontal, 4)

                ForEach(sync.remoteTabs) { device in
                    VStack(alignment: .leading, spacing: ZenMetrics.rowSpacing) {
                        deviceRow(device)
                        if expanded.contains(device.clientGUID) {
                            ForEach(Array(device.tabs.prefix(12))) { tab in
                                remoteTabRow(tab)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("remoteTabsSection")
        }
    }

    private func deviceRow(_ device: RemoteDeviceTabs) -> some View {
        Button {
            Haptics.shared.fire(.tabSelect)
            withAnimation(.easeInOut(duration: 0.18)) {
                if expanded.contains(device.clientGUID) {
                    expanded.remove(device.clientGUID)
                } else {
                    expanded.insert(device.clientGUID)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(device.clientName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(device.tabs.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.text.withAlpha(0.4).color)
                Image(
                    systemName: expanded.contains(device.clientGUID)
                        ? "chevron.down" : "chevron.right"
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.text.withAlpha(0.4).color)
            }
            .foregroundStyle(palette.text.withAlpha(0.75).color)
            .padding(.horizontal, 8)
            .frame(height: ZenMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
    }

    private func remoteTabRow(_ tab: RemoteTabItem) -> some View {
        Button {
            Haptics.shared.fire(.tabOpen)
            state.newTab(url: tab.url)
            if UIDevice.current.userInterfaceIdiom == .phone { state.isSidebarVisible = false }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.text.withAlpha(0.35).color)
                    .frame(width: 16)
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text.withAlpha(0.6).color)
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .frame(height: ZenMetrics.rowHeight - 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
    }
}
