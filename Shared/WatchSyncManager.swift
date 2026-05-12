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
    /// + the active shopping group over `updateApplicationContext`.
    /// WCSession coalesces contexts — only the latest one is delivered
    /// to the watch when it next wakes — so it's safe to call this on
    /// every local mutation. The `isPaired` / `isWatchAppInstalled`
    /// guards from the first version were silently swallowing pushes
    /// on simulator pairs (those flags lie there); we now always
    /// attempt the call and trust the runtime to no-op if there's no
    /// counterpart.
    func pushSnapshot() {
        guard let session = activeSession else { return }
        guard session.activationState == .activated else {
            print("[wc] pushSnapshot skipped: session not activated yet")
            return
        }
        let context = buildSnapshotPayload()
        if context.isEmpty {
            print("[wc] pushSnapshot skipped: no data to send yet")
            return
        }
        do {
            try session.updateApplicationContext(context)
            print("[wc] pushed context with keys=\(context.keys.sorted())")
        } catch {
            print("[wc] updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    /// Watch → iPhone request. Asks iPhone for the latest snapshot
    /// over `sendMessage` (real-time, reply-style) instead of waiting
    /// for the iPhone's next push. Watch views call this on appear so
    /// the first frame after launch isn't empty just because the
    /// iPhone hadn't yet triggered an `updateApplicationContext`. No-
    /// op on iOS — the iPhone is always the producer.
    func requestSnapshotFromPhone() {
        #if os(watchOS)
        guard let session = activeSession else { return }
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            print("[wc] requestSnapshot skipped: counterpart not reachable")
            return
        }
        session.sendMessage(["requestSnapshot": true], replyHandler: { reply in
            Task { @MainActor in
                WatchSyncManager.shared.apply(payload: reply)
            }
        }, errorHandler: { error in
            print("[wc] requestSnapshot failed: \(error.localizedDescription)")
        })
        #endif
    }

    /// Decode an incoming `[String: Any]` snapshot payload into
    /// SharedStore mirrors — used by both the WCSession context path
    /// and the message-reply path so each delivery channel writes the
    /// state the same way.
    @MainActor
    func apply(payload: [String: Any]) {
        var didChange = false
        if let nowData = payload["nowJSON"] as? Data {
            SharedStore.cacheLastNow(nowData)
            didChange = true
        }
        if let shoppingData = payload["shoppingActive"] as? Data,
           let group = try? JSONDecoder().decode(ShoppingGroup.self, from: shoppingData) {
            SharedStore.shoppingActiveGroup = group
            didChange = true
        }
        if didChange {
            NotificationCenter.default.post(name: .watchSyncDidUpdate, object: nil)
        }
    }

    /// Build a single-source-of-truth payload from SharedStore. Shared
    /// between `updateApplicationContext` (iPhone push) and the
    /// `didReceiveMessage` reply (response to watch's request) so the
    /// two channels stay perfectly aligned.
    func buildSnapshotPayload() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let nowData = SharedStore.lastNowJSONData() {
            payload["nowJSON"] = nowData
        }
        if let shoppingData = try? JSONEncoder().encode(SharedStore.shoppingActiveGroup) {
            payload["shoppingActive"] = shoppingData
        }
        return payload
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
        print("[wc] received context with keys=\(applicationContext.keys.sorted())")
        Task { @MainActor in
            WatchSyncManager.shared.apply(payload: applicationContext)
        }
    }

    /// Watch sends `{requestSnapshot: true}` on appear — reply with the
    /// current SharedStore mirror. Handled inline so we don't have to
    /// hop back through `updateApplicationContext` for the first paint.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message["requestSnapshot"] != nil {
            Task { @MainActor in
                let payload = WatchSyncManager.shared.buildSnapshotPayload()
                print("[wc] replying to requestSnapshot with keys=\(payload.keys.sorted())")
                replyHandler(payload)
            }
        } else {
            replyHandler([:])
        }
    }

    /// Reachability flipped — iPhone learns the watch app just woke up,
    /// or the watch learns the iPhone is online. Either way, push the
    /// latest state from whichever side can produce it (iPhone always
    /// can; on watch this is a no-op because pushSnapshot is iOS-only
    /// in spirit, but harmless to call).
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        print("[wc] reachability changed: isReachable=\(session.isReachable)")
        #if os(iOS)
        Task { @MainActor in
            WatchSyncManager.shared.pushSnapshot()
        }
        #endif
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
