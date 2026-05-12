import SwiftUI

/// All pending reminders, sorted by due time. Reads from the cached
/// list the iPhone mirrors via WCSession (`SharedStore.loadReminders`)
/// so the watch can show more than just the single `next_reminder`
/// that lives inside `NowResponse`. The list is read-only on watch
/// for now — completing one still requires opening the iPhone, since
/// the call needs a Firebase ID token and a backend round-trip.
struct WatchRemindersListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminders: [Reminder] = SharedStore.loadReminders()

    var body: some View {
        List {
            if pending.isEmpty {
                emptyRow
            } else {
                Section {
                    ForEach(pending) { r in
                        row(for: r)
                    }
                } header: {
                    Text("פעילות (\(pending.count))")
                }
            }
            if !completed.isEmpty {
                Section {
                    ForEach(completed.prefix(5)) { r in
                        row(for: r)
                            .opacity(0.6)
                    }
                } header: {
                    Text("הושלמו")
                }
            }
        }
        .navigationTitle("תזכורות")
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

    private var pending: [Reminder] {
        reminders
            .filter { $0.status == .pending }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private var completed: [Reminder] {
        reminders
            .filter { $0.status == .completed }
            .sorted { ($0.completed_at ?? "") > ($1.completed_at ?? "") }
    }

    private func refresh() {
        reminders = SharedStore.loadReminders()
    }

    private func row(for r: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.task)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .strikethrough(r.status == .completed)
            HStack(spacing: 4) {
                Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "clock")
                Text(r.dueDate, style: .time)
                    .monospacedDigit()
                Text("·")
                Text(r.dueDate, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(r.isOverdue ? Color.red : .secondary)
        }
    }

    private var emptyRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "bell.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("אין תזכורות")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }
}
