import SwiftUI

/// Sheet that lets the user reorder AND hide home-screen cards. Standard
/// `.editMode = .active` List with drag handles for reorder, plus an eye
/// toggle per row to hide/show. Saves both order and hidden set on dismiss.
struct CustomizeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: ([HomeCardKind], Set<HomeCardKind>) -> Void

    @State private var order: [HomeCardKind]
    @State private var hidden: Set<HomeCardKind>

    init(
        currentOrder: [HomeCardKind],
        currentHidden: Set<HomeCardKind>,
        onSave: @escaping ([HomeCardKind], Set<HomeCardKind>) -> Void
    ) {
        _order = State(initialValue: currentOrder)
        _hidden = State(initialValue: currentHidden)
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
                    Text(tr("גרור לסידור מחדש, ולחץ על העין כדי להסתיר או להציג", "Drag to reorder, and tap the eye to hide or show"))
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                } footer: {
                    Text(tr("כרטיסיות שאין להן מידע (כמו טיסה כשאין הזמנה) יוסתרו אוטומטית, אבל המיקום יישמר אם יחזור מידע.", "Cards with no data (like a flight with no booking) are hidden automatically, but their position is kept if data returns."))
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(LiquidBackdrop())
            .environment(\.editMode, .constant(.active))
            .navigationTitle(tr("סדר את המסך הראשי", "Arrange Home Screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("בטל", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(order, hidden)
                        dismiss()
                    } label: {
                        Text(tr("שמור", "Save")).font(.body.weight(.semibold))
                    }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func row(for card: HomeCardKind) -> some View {
        let isHidden = hidden.contains(card)
        return HStack(spacing: 14) {
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
            Button {
                if isHidden {
                    hidden.remove(card)
                } else {
                    hidden.insert(card)
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isHidden ? .limorMuted : .limorIndigo)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            // Borderless so the row's drag handle (added by editMode) doesn't
            // swallow the tap as part of List selection behaviour.
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .opacity(isHidden ? 0.55 : 1)
    }
}
