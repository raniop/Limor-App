import Foundation

/// Single source of truth for "the user's upcoming calendar events", merged
/// across every source they enabled in the in-app picker — Apple EventKit +
/// Google Calendar + Microsoft Graph (Outlook). Mirrors `SyncManager`'s
/// source-selection so the home card, the full meetings list, and the
/// lead-time notifier all agree with what gets synced to the backend.
///
/// Before this existed, the cards + notifier read EventKit directly, so an
/// Outlook calendar connected via the in-app Microsoft (Graph) flow showed
/// up in Limor's chat but nowhere on-device. Routing all three through here
/// closes that gap.
@MainActor
enum CalendarAggregator {

    /// Fetch + merge upcoming events from all enabled sources. Per-source
    /// failures (missing scope, transient network) are swallowed so one
    /// provider can't blank the others. Deduped and sorted by start time.
    static func upcomingEvents(daysAhead: Int) async -> [CalendarEventDTO] {
        let sources = SharedStore.calendarSources
        var events: [CalendarEventDTO] = []

        if sources.contains(.apple), CalendarManager.shared.hasAccess {
            events.append(contentsOf: CalendarManager.shared.fetchUpcomingEvents(daysAhead: daysAhead))
        }
        if sources.contains(.google) {
            if let g = try? await GoogleAPIs.fetchCalendarEvents(daysAhead: daysAhead) {
                events.append(contentsOf: g)
            }
        }
        if sources.contains(.microsoft) {
            if let m = try? await MicrosoftAPIs.fetchCalendarEvents(daysAhead: daysAhead) {
                events.append(contentsOf: m)
            }
        }

        return dedupe(events).sorted {
            (parseIso($0.start_at) ?? .distantFuture) < (parseIso($1.start_at) ?? .distantFuture)
        }
    }

    /// Whether the app needs (but lacks) EventKit access to honor the user's
    /// source choice — drives the "grant calendar access" hint on the home
    /// card. Only true when Apple is one of the enabled sources.
    static var needsAppleAccess: Bool {
        SharedStore.calendarSources.contains(.apple) && !CalendarManager.shared.hasAccess
    }

    /// True when at least one calendar source is enabled in the picker.
    static var hasAnySource: Bool { !SharedStore.calendarSources.isEmpty }

    /// Ask for EventKit access only if Apple is an enabled source — Graph-only
    /// setups (Outlook/Google) don't need it. Safe to call repeatedly.
    static func ensureAppleAccessIfNeeded() async {
        guard SharedStore.calendarSources.contains(.apple), !CalendarManager.shared.hasAccess else { return }
        _ = await CalendarManager.shared.requestAccess()
    }

    private static func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Collapse both exact-id repeats and the same meeting arriving from two
    /// providers (EventKit + Graph for one linked account) by keying on
    /// title + start time.
    private static func dedupe(_ events: [CalendarEventDTO]) -> [CalendarEventDTO] {
        var seen = Set<String>()
        var out: [CalendarEventDTO] = []
        for ev in events where seen.insert("\(ev.title)|\(ev.start_at)").inserted {
            out.append(ev)
        }
        return out
    }
}
