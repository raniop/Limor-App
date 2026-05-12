import SwiftUI

/// All pending reminders, sorted by due time. Read-only on watch —
/// completing one happens on the iPhone (the iCloud-only flow we use
/// for shopping doesn't extend to reminders, which live on the
/// backend and need a network call to mark complete).
struct WatchRemindersListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: NowResponse? = SharedStore.loadLastNow()

    var body: some View {
        List {
            if let next = snapshot?.next_reminder {
                Section {
                    row(for: next)
                } header: {
                    Text("הקרוב")
                }
            }
            // The cached `NowResponse` only carries the next reminder.
            // For now that's all we can show without a network call;
            // when the user taps "open in app" we hand off to the
            // iPhone via the standard watchOS Continue activity.
            if snapshot?.next_reminder == nil {
                emptyRow
            }
        }
        .navigationTitle("תזכורות")
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refresh() }
        }
        // Phone pushed a new snapshot — re-read the cached
        // `NowResponse` so the watch hero updates instantly.
        .onReceive(NotificationCenter.default.publisher(
            for: .watchSyncDidUpdate
        )) { _ in refresh() }
    }

    private func refresh() {
        snapshot = SharedStore.loadLastNow()
    }

    private func row(for r: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.task)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(r.dueDate, style: .time)
                    .monospacedDigit()
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
