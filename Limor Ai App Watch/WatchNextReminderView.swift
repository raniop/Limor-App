import SwiftUI

/// Hero view: shows the soonest pending reminder + a relative
/// countdown. Refreshes on scenePhase=.active and when the iCloud KVS
/// fires a `didChangeExternallyNotification` (iPhone added/edited a
/// reminder, watch picks it up).
struct WatchNextReminderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: NowResponse? = SharedStore.loadLastNow()

    var body: some View {
        Group {
            if let reminder = snapshot?.next_reminder {
                reminderHero(reminder)
            } else {
                emptyHero
            }
        }
        .onAppear {
            refresh()
            // Pull the current snapshot from iPhone — handles the
            // first-launch case where no `updateApplicationContext`
            // has landed yet, and the simulator-pair case where the
            // App Group containers don't bridge between processes.
            WatchSyncManager.shared.requestSnapshotFromPhone()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
                WatchSyncManager.shared.requestSnapshotFromPhone()
            }
        }
        // KVS notification covers real-device sync; WCSession
        // notification covers the simulator pair and gives instant
        // updates on hardware too.
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: .watchSyncDidUpdate
        )) { _ in refresh() }
    }

    private func refresh() {
        snapshot = SharedStore.loadLastNow()
    }

    private func reminderHero(_ r: Reminder) -> some View {
        let overdue = r.isOverdue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: overdue ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(overdue ? Color.red : Color.indigo)
                Text(overdue ? "באיחור" : "התזכורת הבאה")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(r.task)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(r.dueDate, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(overdue ? Color.red : .primary)
            Text(r.dueDate, style: .time)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHero: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.green)
            Text("הכל רגוע")
                .font(.headline)
            Text("אין תזכורות פעילות")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
    }
}
