import SwiftUI

/// Upcoming calendar events (Apple + Google + Outlook — whatever the
/// iPhone has aggregated through `CalendarManager`). The watch can't
/// touch EventKit itself, so the iPhone serializes the next ~30
/// events into `SharedStore.cachedMeetings` and ships them over
/// WCSession. Read-only — tapping an event would need full
/// navigation back to the iPhone, which we skip for the v1.
struct WatchMeetingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var events: [CalendarEventDTO] = SharedStore.loadMeetings()

    var body: some View {
        List {
            if upcoming.isEmpty {
                emptyRow
            } else {
                ForEach(grouped, id: \.day) { group in
                    Section {
                        ForEach(group.events) { event in
                            row(for: event)
                        }
                    } header: {
                        Text(group.day)
                    }
                }
            }
        }
        .navigationTitle("פגישות")
        .onAppear {
            refresh()
            WatchSyncManager.shared.requestSnapshotFromPhone()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
                WatchSyncManager.shared.requestSnapshotFromPhone()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .watchSyncDidUpdate
        )) { _ in refresh() }
    }

    private var upcoming: [CalendarEventDTO] {
        let now = Date()
        return events
            .compactMap { event -> (CalendarEventDTO, Date)? in
                guard let end = parseIso(event.end_at), end > now else { return nil }
                guard let start = parseIso(event.start_at) else { return nil }
                return (event, start)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    /// Group upcoming events by day for a clean readable list.
    private var grouped: [(day: String, events: [CalendarEventDTO])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "he_IL")
        formatter.dateFormat = "EEEE, d MMMM"
        var sections: [(String, [CalendarEventDTO])] = []
        for event in upcoming {
            guard let start = parseIso(event.start_at) else { continue }
            let key = formatter.string(from: start)
            if let last = sections.last, last.0 == key {
                sections[sections.count - 1].1.append(event)
            } else {
                sections.append((key, [event]))
            }
        }
        return sections
    }

    private func refresh() {
        events = SharedStore.loadMeetings()
    }

    private func row(for event: CalendarEventDTO) -> some View {
        let start = parseIso(event.start_at)
        return VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "clock")
                if let start {
                    Text(start, style: .time)
                        .monospacedDigit()
                }
                if let location = event.location, !location.isEmpty {
                    Text("·")
                    Text(location)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("אין פגישות בקרוב")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
