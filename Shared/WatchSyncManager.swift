import Foundation
import WatchConnectivity

/// Two-way live sync between the iPhone and the paired Apple Watch
/// over `WCSession`. The App Group + iCloud KVS path works on real
/// devices but Apple's simulators run as fully isolated processes —
/// the iPhone simulator and the Watch simulator literally can't see
/// each other's `UserDefaults(suiteName:)` containers. WCSession is
/// the only mechanism that bridges them at dev time, and it also
/// gives us instant updates on real hardware (faster than the iCloud
/// KVS propagation, which has a 5–60s window).
///
/// Both sides activate the same singleton. iPhone calls `pushSnapshot()`
/// after any local SharedStore mutation it wants the watch to see;
/// the watch updates its local SharedStore mirror inside the
/// `didReceiveApplicationContext` callback and posts
/// `Notification.Name.watchSyncDidUpdate` so the watch UI refreshes.
@MainActor
final class WatchSyncManager: NSObject, ObservableObject {
    static let shared = WatchSyncManager()

    /// Lazily fetch the activated session, kicking off `activate()` on
    /// first access. Returns nil when the platform doesn't support
    /// WCSession at all (e.g. iPad).
    private var activeSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        if session.delegate !== self { session.delegate = self }
        if session.activationState == .notActivated { session.activate() }
        return session
    }

    /// Idempotent — wires up the delegate and starts activation. Safe
    /// to call on every app launch; subsequent calls no-op.
    func activate() {
        _ = activeSession
    }

    /// iPhone → Watch broadcast. Sends the latest `NowResponse` cache
    /// (used by the watch's hero view) + the active shopping group
    /// over `updateApplicationContext`. WCSession coalesces contexts —
    /// only the latest one is delivered to the watch when it wakes —
    /// so it's safe to call this on every local mutation.
    func pushSnapshot() {
        guard let session = activeSession else { return }
        guard session.activationState == .activated else { return }
        // Only iPhone has a counterpart; on watch this guard prevents
        // the watch from pushing back state it just received.
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        var context: [String: Any] = [:]
        if let nowData = SharedStore.lastNowJSONData() {
            context["nowJSON"] = nowData
        }
        if let shoppingData = try? JSONEncoder().encode(SharedStore.shoppingActiveGroup) {
            context["shoppingActive"] = shoppingData
        }
        if context.isEmpty { return }
        do {
            try session.updateApplicationContext(context)
        } catch {
            print("[wc] updateApplicationContext failed: \(error.localizedDescription)")
        }
    }
}

extension WatchSyncManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        print("[wc] activation state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "nil")")
        // After the iPhone activates, fire an initial push so the
        // newly-paired (or just-launched) watch gets the current
        // snapshot without waiting for the next user action.
        #if os(iOS)
        if activationState == .activated {
            Task { @MainActor in
                WatchSyncManager.shared.pushSnapshot()
            }
        }
        #endif
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            var didChange = false
            if let nowData = applicationContext["nowJSON"] as? Data {
                SharedStore.cacheLastNow(nowData)
                didChange = true
            }
            if let shoppingData = applicationContext["shoppingActive"] as? Data,
               let group = try? JSONDecoder().decode(ShoppingGroup.self, from: shoppingData) {
                SharedStore.shoppingActiveGroup = group
                didChange = true
            }
            if didChange {
                NotificationCenter.default.post(name: .watchSyncDidUpdate, object: nil)
            }
        }
    }

    #if os(iOS)
    // iOS-only — when the user pairs / unpairs a watch the session
    // bounces; just reactivate so the watch keeps receiving updates.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}

extension Notification.Name {
    /// Fired on the watch after WCSession delivers a new application
    /// context. Watch views observe this to re-read SharedStore.
    static let watchSyncDidUpdate = Notification.Name("limor.watchSync.didUpdate")
}
