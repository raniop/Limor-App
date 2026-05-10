import SwiftUI

/// Sheet that lets the user reorder the home-screen cards. Standard
/// `.editMode = .active` List with drag handles, plus icon + title per row.
/// Saves to SharedStore on dismiss.
struct CustomizeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: ([HomeCardKind]) -> Void

    @State private var order: [HomeCardKind]

    init(currentOrder: [HomeCardKind], onSave: @escaping ([HomeCardKind]) -> Void) {
        _order = State(initialValue: currentOrder)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { card in
                        row(for: card)
                    }
                    .onMove { indices, newOffset in
                        order.move(fromOffsets: indices, toOffset: newOffset)
                    }
                } header: {
                    Text("גרור לסידור מחדש")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                } footer: {
                    Text("כרטיסיות שאין להן מידע (כמו טיסה כשאין הזמנה) יוסתרו אוטומטית, אבל המיקום יישמר אם יחזור מידע.")
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(LiquidBackdrop())
            .environment(\.editMode, .constant(.active))
            .navigationTitle("סדר את המסך הראשי")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("בטל") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(order)
                        dismiss()
                    } label: {
                        Text("שמור").font(.body.weight(.semibold))
                    }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func row(for card: HomeCardKind) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(card.tint.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: card.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(card.tint)
            }
            Text(card.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.limorInk)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
