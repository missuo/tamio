//
//  SyncTransport.swift
//  TamioModule
//
//  Where the sealed document is kept. iCloud's key-value store holds it as one
//  value: it is small (servers and identities compress to a few kilobytes), it
//  reaches every device signed in to the same iCloud account, and a change
//  made elsewhere is announced.
//

import Foundation

enum SyncTransportError: LocalizedError {
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "There is more to sync than iCloud keeps for an app (1 MB).")
        }
    }
}

@MainActor
protocol SyncTransport: AnyObject {
    /// Why nothing can be stored, in a sentence; nil when it can.
    var problem: String? { get }
    /// Called when another device has stored something.
    var changed: (() -> Void)? { get set }
    func read() -> Data?
    func write(_ data: Data?) throws
}

@MainActor
final class CloudKeyValueTransport: SyncTransport {
    private static let key = "sync.v1"
    private static let limit = 1_000_000

    var changed: (() -> Void)?
    private var observer: NSObjectProtocol?

    /// The store is not touched by a build that iCloud would refuse.
    private lazy var cloud: NSUbiquitousKeyValueStore = {
        let cloud = NSUbiquitousKeyValueStore.default
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed?() }
        }
        cloud.synchronize()
        return cloud
    }()

    var problem: String? {
        Self.isEntitled ? nil : String(localized: "This copy of Tamio is not signed for iCloud, so it cannot sync.")
    }

    func read() -> Data? {
        guard Self.isEntitled else { return nil }
        return cloud.data(forKey: Self.key)
    }

    func write(_ data: Data?) throws {
        guard Self.isEntitled else { return }
        if let data {
            guard data.count <= Self.limit else { throw SyncTransportError.tooLarge }
            cloud.set(data, forKey: Self.key)
        } else {
            cloud.removeObject(forKey: Self.key)
        }
        cloud.synchronize()
    }

    /// Whether the app is signed for the iCloud key-value store. Without the
    /// entitlement the store silently stays on the device, which would look
    /// like sync and not be.
    static let isEntitled: Bool = {
        let entitlement = "com.apple.developer.ubiquity-kvstore-identifier"
        #if targetEnvironment(macCatalyst) || os(macOS)
            // The Mac says what the running signature holds.
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil
        #else
            // iOS does not; there the provisioning profile is asked, which the
            // scripts that sign the app follow.
            return profileGrants(entitlement)
        #endif
    }()

    private static func profileGrants(_ entitlement: String) -> Bool {
        let profile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        // A signed (CMS) file with a property list inside.
        guard let data = try? Data(contentsOf: profile),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound ..< data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound ..< end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return false }
        return entitlements[entitlement] != nil
    }
}

#if DEBUG
    /// Stands in for iCloud on a build that has none, to see sync at work on
    /// one device. Set TAMIO_SYNC_LOCAL in the environment.
    @MainActor
    /// iCloud stood in for, to try sync without it: the app's defaults, or a
    /// file named by TAMIO_SYNC_FILE that several copies of the app share,
    /// each looking for the others' writes every two seconds.
    final class LocalTransport: SyncTransport {
        private static let key = "sb.moe.tamio.debug.sync"
        private let file = ProcessInfo.processInfo.environment["TAMIO_SYNC_FILE"].map { URL(fileURLWithPath: $0) }
        private var seen: Data?
        private var timer: Timer?
        var changed: (() -> Void)? {
            didSet {
                guard file != nil, timer == nil else { return }
                seen = read()
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let now = read()
                    if now != seen { seen = now; changed?() }
                }
            }
        }

        var problem: String? { nil }

        func read() -> Data? {
            if let file { return try? Data(contentsOf: file) }
            return UserDefaults.standard.data(forKey: Self.key)
        }

        func write(_ data: Data?) throws {
            if let file {
                if let data { try data.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
                seen = data
                return
            }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
#endif
