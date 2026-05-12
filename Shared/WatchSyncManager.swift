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

    #if os(iOS)
    /// iPhone-side handler for the watch's recorded audio. Writes the
    /// bytes to a temp m4a, transcribes via the existing iOS
    /// `VoiceService.transcribeAudioFile` (Hebrew Speech recognizer
    /// — only available on iOS, which is why the watch hands off
    /// here in the first place), then routes the transcript through
    /// the same intercept + chat path as a typed message would.
    func relayLimorVoice(_ audio: Data, replyHandler: @escaping ([String: Any]) -> Void) async {
        let url = ChatMessage.voiceMessagesDirectory
            .appendingPathComponent("watch-relay-\(UUID().uuidString).m4a")
        do {
            try audio.write(to: url)
        } catch {
            replyHandler(["error": "לא הצלחתי לשמור את ההקלטה: \(error.localizedDescription)"])
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let transcript = await VoiceService.shared.transcribeAudioFile(url: url, locale: .hebrew)
        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            replyHandler(["error": "לא הצלחתי להבין את ההקלטה"])
            return
        }
        await relayLimorMessage(trimmed, replyHandler: replyHandler)
    }

    /// iPhone-side handler for the watch's PTT button. Mirrors what
    /// `ChatView.send(text:)` does: first runs the on-device
    /// `ShoppingDetector` intercept (which is what actually writes
    /// items into `ShoppingListStore` — without this, a single word
    /// like "עגבניות" lands in the chat backend whose LLM sometimes
    /// confirms "הוספתי" without calling the tool, leaving the list
    /// empty). Only when the intercept doesn't fire do we hit the
    /// chat backend.
    func relayLimorMessage(_ text: String, replyHandler: @escaping ([String: Any]) -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Local grocery intercept — same logic the text-side chat
        //    uses. Writes directly to the on-device store, no network
        //    round-trip, never lies.
        let items = ShoppingDetector.extractShoppingItems(trimmed)
        if !items.isEmpty {
            var added: [String] = []
            var existing: [String] = []
            for item in items {
                if ShoppingListStore.shared.add(item) {
                    added.append(item)
                } else {
                    existing.append(item)
                }
            }
            var lines: [String] = []
            if !added.isEmpty {
                let joined = added.joined(separator: ", ")
                let verb = added.count == 1 ? "הוספתי" : "הוספתי \(added.count) פריטים"
                lines.append("🛒 \(verb) לרשימת הקניות: \(joined)")
            }
            if !existing.isEmpty {
                let joined = existing.joined(separator: ", ")
                lines.append("ℹ️ כבר היו ברשימה: \(joined)")
            }
            replyHandler(["reply": lines.joined(separator: "\n")])
            pushSnapshot()
            return
        }

        // 2. Otherwise — chat backend. Honor the same
        //    `shopping_actions` echo path the iOS chat already runs.
        do {
            let reply = try await APIClient.shared.sendChat(
                token: "",
                message: trimmed,
                lat: nil,
                lng: nil,
                attachment: nil
            )
            if let actions = reply.shopping_actions {
                for name in actions.adds {
                    _ = ShoppingListStore.shared.add(name)
                }
                for name in actions.completes {
                    _ = ShoppingListStore.shared.completeByName(name)
                }
            }
            replyHandler(["reply": reply.reply])
            // Re-push the latest state to the watch so the shopping
            // list reflects whatever changed.
            pushSnapshot()
        } catch {
            replyHandler(["error": error.localizedDescription])
        }
    }
    #endif

    #if os(watchOS)
    /// Watch → iPhone PTT bridge for AUDIO. Ships the recorded m4a
    /// bytes over `sendMessage`, iPhone transcribes them locally and
    /// routes through the same shopping intercept / chat backend
    /// path the typed message uses, then returns Limor's reply
    /// inline.
    func askLimorVoice(_ audio: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = activeSession else {
            completion(.failure(WatchSyncError.notSupported))
            return
        }
        guard session.activationState == .activated else {
            completion(.failure(WatchSyncError.notActivated))
            return
        }
        guard session.isReachable else {
            completion(.failure(WatchSyncError.phoneUnreachable))
            return
        }
        session.sendMessage(
            ["voiceAudio": audio],
            replyHandler: { reply in
                Task { @MainActor in
                    if let text = reply["reply"] as? String {
                        completion(.success(text))
                    } else if let err = reply["error"] as? String {
                        completion(.failure(WatchSyncError.phone(message: err)))
                    } else {
                        completion(.failure(WatchSyncError.malformedReply))
                    }
                }
            },
            errorHandler: { error in
                Task { @MainActor in completion(.failure(error)) }
            }
        )
    }

    /// Watch → iPhone PTT bridge for TEXT (legacy / dictation path).
    func askLimor(_ message: String, completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(WatchSyncError.emptyMessage))
            return
        }
        guard let session = activeSession else {
            completion(.failure(WatchSyncError.notSupported))
            return
        }
        guard session.activationState == .activated else {
            completion(.failure(WatchSyncError.notActivated))
            return
        }
        guard session.isReachable else {
            completion(.failure(WatchSyncError.phoneUnreachable))
            return
        }
        session.sendMessage(
            ["limorMessage": trimmed],
            replyHandler: { reply in
                Task { @MainActor in
                    if let text = reply["reply"] as? String {
                        completion(.success(text))
                    } else if let err = reply["error"] as? String {
                        completion(.failure(WatchSyncError.phone(message: err)))
                    } else {
                        completion(.failure(WatchSyncError.malformedReply))
                    }
                }
            },
            errorHandler: { error in
                Task { @MainActor in
                    completion(.failure(error))
                }
            }
        )
    }
    #endif
}

enum WatchSyncError: LocalizedError {
    case emptyMessage
    case notSupported
    case notActivated
    case phoneUnreachable
    case phone(message: String)
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .emptyMessage:      return "אין מה לשלוח"
        case .notSupported:      return "WCSession לא נתמך"
        case .notActivated:      return "החיבור לאייפון עוד לא מוכן"
        case .phoneUnreachable:  return "האייפון לא בטווח"
        case .phone(let m):      return m
        case .malformedReply:    return "התשובה מהאייפון לא תקינה"
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
        print("[wc] received context with keys=\(applicationContext.keys.sorted())")
        Task { @MainActor in
            WatchSyncManager.shared.apply(payload: applicationContext)
        }
    }

    /// Watch sends `{requestSnapshot: true}` on appear — reply with the
    /// current SharedStore mirror. The PTT button on the watch sends
    /// `{limorMessage: text}` — iPhone hands it to Limor's chat
    /// backend and returns the reply in the reply handler.
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
            return
        }
        #if os(iOS)
        if let text = message["limorMessage"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { @MainActor in
                await WatchSyncManager.shared.relayLimorMessage(text, replyHandler: replyHandler)
            }
            return
        }
        if let audio = message["voiceAudio"] as? Data, !audio.isEmpty {
            Task { @MainActor in
                await WatchSyncManager.shared.relayLimorVoice(audio, replyHandler: replyHandler)
            }
            return
        }
        #endif
        replyHandler([:])
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
