import EventKit
import Foundation

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    private let store = EKEventStore()
    @Published private(set) var hasAccess = false

    /// iOS 17+ split read/write into separate permissions. We ask for full access
    /// because the chat tools need to be able to *write* events later (read-only
    /// would limit `today_events` etc. fine but blocks `create_event`).
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            hasAccess = granted
            return granted
        } catch {
            hasAccess = false
            return false
        }
    }

    /// Fetch events from now through `daysAhead` calendar days, across all calendars
    /// the user has authorized. Skips fetched-but-unidentifiable events.
    func fetchUpcomingEvents(daysAhead: Int = 60) -> [CalendarEventDTO] {
        guard hasAccess else { return [] }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        let formatter = ISO8601DateFormatter.limor

        return events.compactMap { event -> CalendarEventDTO? in
            guard let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }
            return CalendarEventDTO(
                event_id: identifier,
                title: event.title?.isEmpty == false ? event.title : "(ללא כותרת)",
                notes: event.notes?.isEmpty == false ? event.notes : nil,
                location: event.location?.isEmpty == false ? event.location : nil,
                start_at: formatter.string(from: event.startDate),
                end_at: formatter.string(from: event.endDate),
                is_all_day: event.isAllDay,
                calendar_name: event.calendar?.title
            )
        }
    }
}
