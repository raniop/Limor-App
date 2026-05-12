import SwiftUI

/// Tap to toggle an item complete. Reads state from
/// `SharedStore.shoppingActiveGroup` (same App Group the iPhone writes
/// to) and writes back the same way — the iPhone's
/// `ShoppingListStore` 5-second iCloud poll + KVS change notification
/// picks up the watch's mutation within seconds.
struct WatchShoppingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeGroup: ShoppingGroup = SharedStore.shoppingActiveGroup

    var body: some View {
        List {
            if openItems.isEmpty {
                emptyRow
            } else {
                ForEach(openItems) { item in
                    Button { toggle(item) } label: {
                        HStack {
                            Image(systemName: "circle")
                                .foregroundStyle(Color.indigo)
                            Text(item.name)
                                .font(.body)
                            Spacer()
                        }
                    }
                }
            }
            if !completedItems.isEmpty {
                Section("הושלמו") {
                    ForEach(completedItems) { item in
                        Button { toggle(item) } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                Text(item.name)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("קניות")
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in refresh() }
        // WCSession path — the only one that works on simulator pairs
        // (the App Group + iCloud KVS path requires real paired
        // hardware to bridge between iPhone and watch).
        .onReceive(NotificationCenter.default.publisher(
            for: .watchSyncDidUpdate
        )) { _ in refresh() }
    }

    private var openItems: [ShoppingItem] {
        activeGroup.items.filter { !$0.completed }
    }

    private var completedItems: [ShoppingItem] {
        activeGroup.items.filter { $0.completed }
    }

    private var emptyRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "cart")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("הרשימה ריקה")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private func refresh() {
        // Force iCloud to sync down anything the iPhone wrote while we
        // were asleep, then re-read.
        SharedStore.mirrorShoppingFromICloud()
        activeGroup = SharedStore.shoppingActiveGroup
    }

    /// Flip the item locally + persist. SharedStore writes to App
    /// Group UserDefaults *and* the iCloud KVS, so the iPhone sees the
    /// change within ~5s without us needing Watch Connectivity.
    private func toggle(_ item: ShoppingItem) {
        guard let idx = activeGroup.items.firstIndex(where: { $0.id == item.id }) else { return }
        WKInterfaceDevice.current().play(.click)
        activeGroup.items[idx].completed.toggle()
        // If we just ticked off the last open one, archive the group
        // — mirrors the iPhone's `toggle` behavior so a fully-checked
        // list disappears here too.
        if activeGroup.items.allSatisfy({ $0.completed }), !activeGroup.items.isEmpty {
            var done = activeGroup
            done.archived_at = ISO8601DateFormatter.limor.string(from: Date())
            var archive = SharedStore.shoppingArchive
            archive.insert(done, at: 0)
            SharedStore.shoppingArchive = archive
            activeGroup = ShoppingGroup()
        }
        SharedStore.shoppingActiveGroup = activeGroup
    }
}

import WatchKit
