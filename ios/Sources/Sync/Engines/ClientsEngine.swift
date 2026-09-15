//  ClientsEngine.swift
//  The `clients` collection — how the account knows this phone exists.
//
//  Every device that syncs publishes one record. It is what makes "Send tab to
//  device" list us on the desktop, and what makes the desktop's Synced Tabs
//  sidebar label our tabs with a name rather than a guid. Small, but leaving it
//  out makes the phone invisible to every other client.

import Foundation
import UIKit

struct SyncDeviceRecord: Equatable, Sendable {
    var guid: String
    var name: String
    /// `desktop` or `mobile`. The desktop picks an icon from this.
    var type: String = "mobile"
    var os: String = "iOS"
    var version: String
    var application: String = "Zen"
    var device: String

    var json: JSONValue {
        .object([
            "id": .string(guid),
            "name": .string(name),
            "type": .string(type),
            "version": .string(version),
            "protocols": .array([.string(SyncConfig.syncProtocolVersion)]),
            "os": .string(os),
            "appPackage": .string(Bundle.main.bundleIdentifier ?? "com.morton.zen"),
            "application": .string(application),
            "device": .string(device),
            "formfactor": .string(formFactor),
        ])
    }

    private var formFactor: String {
        device.lowercased().contains("ipad") ? "tablet" : "phone"
    }

    static func parse(_ record: DecryptedRecord) -> SyncDeviceRecord? {
        let payload = record.payload
        guard let name = payload["name"]?.stringValue else { return nil }
        return SyncDeviceRecord(
            guid: record.id, name: name,
            type: payload["type"]?.stringValue ?? "desktop",
            os: payload["os"]?.stringValue ?? "",
            version: payload["version"]?.stringValue ?? "",
            application: payload["application"]?.stringValue ?? "",
            device: payload["device"]?.stringValue ?? "")
    }
}

enum ClientsEngine {
    static let collection = "clients"

    /// The default device name. `UIDevice.name` is the owner's own label for
    /// the phone ("Andy's iPhone") when they have granted the entitlement, and
    /// a generic model name otherwise — either is a better guess than "iOS
    /// device", and the Settings field lets it be corrected.
    @MainActor
    static func defaultDeviceName() -> String {
        let device = UIDevice.current
        let name = device.name
        return name.isEmpty ? "Zen on \(device.model)" : "\(name) — Zen"
    }

    @MainActor
    static func record(guid: String, name: String) -> SyncDeviceRecord {
        SyncDeviceRecord(
            guid: guid, name: name,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "0.1.0",
            device: UIDevice.current.model)
    }
}
