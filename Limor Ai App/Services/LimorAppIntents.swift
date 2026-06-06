import AppIntents
import Foundation
import SwiftUI

// MARK: - Shopping list

/// "הוסף ביצים לרשימת קניות בלימור" — adds a single item to the active
/// shopping list. Works without launching the app: ShoppingListStore
/// reads/writes through SharedStore (App Group UserDefaults + iCloud
/// KVS), so the change is visible the next time the user opens the app
/// and propagates to other devices via iCloud immediately.
struct AddShoppingItemIntent: AppIntent {
    static var title: LocalizedStringResource = "הוסף לרשימת קניות"
    static var description = IntentDescription(
        "מוסיף פריט יחיד לרשימת הקניות הפעילה."
    )

    @Parameter(
        title: "פריט",
        description: "השם של המוצר להוסיף — לדוגמה \"חלב\", \"ביצים\"."
    )
    var item: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "השם של הפריט ריק.")
        }
        let added = ShoppingListStore.shared.add(trimmed)
        let dialog: IntentDialog = added
            ? "🛒 הוספתי \(trimmed) לרשימת הקניות"
            : "ℹ️ \(trimmed) כבר ברשימה."
        return .result(dialog: dialog)
    }
}

/// "מה ברשימת הקניות בלימור" — returns the open items so a Shortcut can
/// pipe them into a notification, a text, or just speak them.
struct ShowShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource = "הצג את רשימת הקניות"
    static var description = IntentDescription(
        "מחזיר את הפריטים שעדיין לא נקנו ברשימה הפעילה."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let openItems = ShoppingListStore.shared.activeGroup.items
            .filter { !$0.completed }
            .map { $0.name }
        let dialog: IntentDialog
        if openItems.isEmpty {
            dialog = "הרשימה ריקה כרגע 🛒"
        } else if openItems.count == 1 {
            dialog = "ברשימה יש פריט אחד: \(openItems[0])"
        } else {
            dialog = "ברשימה יש \(openItems.count) פריטים: \(openItems.joined(separator: ", "))"
        }
        return .result(value: openItems, dialog: dialog)
    }
}

// MARK: - Reminders

/// "תזכורת חדשה בלימור" — creates a reminder via the backend. Requires
/// the user to be signed in (Firebase ID token); if they aren't, the
/// intent surfaces a friendly error so a Shortcut doesn't fail
/// silently.
struct CreateReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "צור תזכורת"
    static var description = IntentDescription(
        "יוצר תזכורת חדשה בלימור ובאפליקציית התזכורות של iOS."
    )

    @Parameter(title: "מה לזכור", description: "תיאור המשימה.")
    var task: String

    @Parameter(title: "מתי", description: "תאריך ושעה לתזכורת.")
    var dueAt: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            return .result(dialog: "מה תרצה שאזכיר?")
        }
        do {
            let created = try await APIClient.shared.createReminder(
                token: "",
                task: trimmedTask,
                dueAt: dueAt
            )
            // Best-effort mirror to iOS Reminders.app + Apple Calendar —
            // the user wanted these to live in both Apple surfaces, and
            // the writers are idempotent (skip already-mirrored IDs), so
            // calling them from here is safe.
            await RemindersWriter.shared.writeIfNeeded(
                reminderId: created.id,
                task: created.task,
                dueAt: created.dueDate
            )
            await CalendarManager.shared.writeReminderAsEventIfNeeded(
                reminderId: created.id,
                task: created.task,
                dueAt: created.dueDate
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "he_IL")
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let when = formatter.string(from: dueAt)
            return .result(dialog: "⏰ נקבעה תזכורת: \(trimmedTask) — \(when)")
        } catch {
            return .result(dialog: "לא הצלחתי לקבוע תזכורת: \(error.localizedDescription)")
        }
    }
}

/// "התזכורות שלי בלימור" — returns the user's pending reminders. Useful
/// inside Shortcuts that build dashboards / morning routines.
struct ShowRemindersIntent: AppIntent {
    static var title: LocalizedStringResource = "הצג את התזכורות הפעילות"
    static var description = IntentDescription(
        "מחזיר את התזכורות שעוד לא בוצעו, ממוינות לפי הזמן."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        do {
            let raw = try await APIClient.shared.listReminders(token: "")
            let pending = raw
                .filter { $0.status == .pending }
                .sorted { $0.dueDate < $1.dueDate }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "he_IL")
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let lines = pending.map { "\($0.task) — \(formatter.string(from: $0.dueDate))" }
            let dialog: IntentDialog
            if pending.isEmpty {
                dialog = "אין תזכורות פעילות 🌿"
            } else if pending.count == 1, let first = lines.first {
                dialog = "יש תזכורת אחת: \(first)"
            } else {
                dialog = "יש \(pending.count) תזכורות פעילות"
            }
            return .result(value: lines, dialog: dialog)
        } catch {
            return .result(value: [], dialog: "לא הצלחתי לקרוא את התזכורות: \(error.localizedDescription)")
        }
    }
}

// MARK: - Chat handoff

/// "שאל את לימור" — opens the chat tab with a pre-filled message ready
/// to send. We don't make the network call from inside the intent
/// because Limor's reply is best shown in the actual chat thread (with
/// her avatar, the bubble, the audio playback for voice messages).
struct AskLimorIntent: AppIntent {
    static var title: LocalizedStringResource = "שלח הודעה ללימור"
    static var description = IntentDescription(
        "פותח את לימור עם הודעה מוכנה לשליחה — שימושי לבנות שורטקאט שמפעיל את לימור עם שאלה קבועה."
    )

    @Parameter(title: "ההודעה", description: "מה לשלוח ללימור.")
    var message: String

    /// Open the host app so the user can see Limor's reply in context.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result() }
        AppRouter.shared.sendToLimor(trimmed)
        return .result()
    }
}

// MARK: - Shortcuts registration

/// Surfaces every intent in the iOS Shortcuts app + Siri. Free-form
/// String parameters can't appear inline in Siri phrases (Siri needs
/// an `AppEntity` / `AppEnum` to bind onto), so the phrases just
/// trigger the intent and Siri / Shortcuts prompt the user for the
/// missing value. Inside the Shortcuts app the user still wires
/// values to parameters in the normal block-builder UI.
struct LimorShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddShoppingItemIntent(),
            phrases: [
                "הוסף פריט לרשימת הקניות ב־\(.applicationName)",
                "הוסף לרשימת קניות ב־\(.applicationName)",
                "Add an item to my shopping list in \(.applicationName)",
            ],
            shortTitle: "הוסף לקניות",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: ShowShoppingListIntent(),
            phrases: [
                "מה ברשימת הקניות ב־\(.applicationName)",
                "מה צריך לקנות ב־\(.applicationName)",
                "What's on the shopping list in \(.applicationName)",
            ],
            shortTitle: "רשימת הקניות",
            systemImageName: "cart.fill"
        )
        AppShortcut(
            intent: CreateReminderIntent(),
            phrases: [
                "תזכורת חדשה ב־\(.applicationName)",
                "צור תזכורת ב־\(.applicationName)",
                "New reminder in \(.applicationName)",
            ],
            shortTitle: "תזכורת חדשה",
            systemImageName: "bell.badge.fill"
        )
        AppShortcut(
            intent: ShowRemindersIntent(),
            phrases: [
                "התזכורות שלי ב־\(.applicationName)",
                "מה התזכורות שלי ב־\(.applicationName)",
                "My reminders in \(.applicationName)",
            ],
            shortTitle: "התזכורות שלי",
            systemImageName: "list.bullet.rectangle.portrait.fill"
        )
        AppShortcut(
            intent: AskLimorIntent(),
            phrases: [
                "שאל את \(.applicationName)",
                "תגיד ל־\(.applicationName)",
                "Ask \(.applicationName)",
            ],
            shortTitle: "שאל את לימור",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}
