import SwiftUI

// MARK: - Store (observable wrapper around SharedStore.recurringReminders)

@MainActor
final class RecurringRemindersStore: ObservableObject {
    static let shared = RecurringRemindersStore()

    @Published private(set) var items: [RecurringReminder]

    private init() {
        self.items = SharedStore.recurringReminders
    }

    func add(_ reminder: RecurringReminder) {
        items.append(reminder)
        persistAndReschedule()
    }

    func update(_ reminder: RecurringReminder) {
        guard let idx = items.firstIndex(where: { $0.id == reminder.id }) else { return }
        items[idx] = reminder
        persistAndReschedule()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persistAndReschedule()
    }

    func togglePause(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].paused.toggle()
        persistAndReschedule()
    }

    private func persistAndReschedule() {
        SharedStore.recurringReminders = items
        Task { await RecurringRemindersScheduler.reschedule() }
    }
}

// MARK: - Hebrew weekday labels

private let weekdayShort = ["א", "ב", "ג", "ד", "ה", "ו", "ש"]
private let weekdayLong  = ["יום ראשון", "יום שני", "יום שלישי", "יום רביעי", "יום חמישי", "יום שישי", "שבת"]

/// Formats a Set of `Calendar.weekday` integers (1...7) as a short Hebrew
/// summary — "א, ג, ה" for selected days, "כל יום" when all 7 are
/// selected, "ימי חול" / "סופ״ש" when those exact sets match.
private func weekdayList(_ days: Set<Int>) -> String {
    guard !days.isEmpty else { return "" }
    if days.count == 7 { return "כל יום" }
    if days == [1, 2, 3, 4, 5] { return "ימי חול (א–ה)" }
    if days == [6, 7] { return "סופ״ש (ו, ש)" }
    return days.sorted().map { weekdayShort[$0 - 1] }.joined(separator: ", ")
}

// MARK: - List view

struct RecurringRemindersView: View {
    @StateObject private var store = RecurringRemindersStore.shared
    @State private var showingNew = false
    @State private var editing: RecurringReminder?

    var body: some View {
        ZStack {
            LiquidBackdrop()
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("תזכורות חוזרות")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(LimorGradient.brand))
                        .shadow(color: Color.limorIndigo.opacity(0.4), radius: 10, y: 4)
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            RecurringReminderEditor(initial: nil) { reminder in
                store.add(reminder)
                Task { await RecurringRemindersScheduler.ensureAuthorization() }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { reminder in
            RecurringReminderEditor(initial: reminder) { updated in
                store.update(updated)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(store.items) { reminder in
                    row(for: reminder)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func row(for reminder: RecurringReminder) -> some View {
        Button {
            editing = reminder
        } label: {
            GlassCard(padding: 14) {
                HStack(alignment: .center, spacing: 14) {
                    timeBadge(reminder)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(reminder.task)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(reminder.paused ? .limorMuted : .limorInk)
                            .strikethrough(reminder.paused)
                            .lineLimit(2)
                        Text(weekdayList(reminder.daysOfWeek))
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                    }

                    Spacer(minLength: 0)

                    Toggle("", isOn: Binding(
                        get: { !reminder.paused },
                        set: { _ in store.togglePause(reminder.id) }
                    ))
                    .labelsHidden()
                    .tint(.limorIndigo)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                store.remove(reminder.id)
            } label: {
                Label("מחק", systemImage: "trash")
            }
        }
    }

    private func timeBadge(_ reminder: RecurringReminder) -> some View {
        VStack(spacing: 0) {
            Text(String(format: "%02d", reminder.hour))
                .font(.title3.weight(.bold).monospacedDigit())
            Text(String(format: "%02d", reminder.minute))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.limorMuted)
        }
        .foregroundStyle(reminder.paused ? .limorMuted : .limorInk)
        .frame(width: 52, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(reminder.paused ? Color.limorMuted.opacity(0.10) : Color.limorIndigo.opacity(0.12))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "alarm")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text("אין עדיין תזכורות חוזרות")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text("הוסף תזכורת חוזרת — לדוגמה, השכמה בכל יום שלישי בשעה 07:45.")
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingNew = true
            } label: {
                Text("צור תזכורת חוזרת")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(LimorGradient.brand))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Add / edit sheet

struct RecurringReminderEditor: View {
    let initial: RecurringReminder?
    var onSave: (RecurringReminder) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var task: String
    @State private var days: Set<Int>
    @State private var time: Date

    init(initial: RecurringReminder?, onSave: @escaping (RecurringReminder) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _task = State(initialValue: initial?.task ?? "")
        _days = State(initialValue: initial?.daysOfWeek ?? [Calendar.current.component(.weekday, from: Date())])
        var comps = DateComponents()
        comps.hour = initial?.hour ?? 7
        comps.minute = initial?.minute ?? 45
        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        taskField
                        timeField
                        daysField
                        if !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !days.isEmpty {
                            previewLine
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(initial == nil ? "תזכורת חוזרת" : "ערוך תזכורת")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("ביטול") { dismiss() }
                        .foregroundStyle(.limorMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("שמור") {
                        save()
                    }
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.limorIndigo)
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !days.isEmpty
    }

    private var taskField: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("מה להזכיר")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                TextField("השכמה לפילאטיס", text: $task, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...3)
            }
        }
    }

    private var timeField: some View {
        GlassCard(padding: 16) {
            HStack {
                Text("שעת ההתראה")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Spacer()
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    private var daysField: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ימים בשבוע")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                // Hebrew weekday order — Sunday is the first column on the
                // right in RTL, which feels natural here.
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { weekday in
                        dayChip(weekday)
                    }
                }
                HStack(spacing: 8) {
                    quickPick(label: "כל יום", target: Set(1...7))
                    quickPick(label: "ימי חול", target: [1, 2, 3, 4, 5])
                    quickPick(label: "סופ״ש", target: [6, 7])
                }
            }
        }
    }

    private func dayChip(_ weekday: Int) -> some View {
        let selected = days.contains(weekday)
        return Button {
            if selected { days.remove(weekday) }
            else { days.insert(weekday) }
        } label: {
            Text(weekdayShort[weekday - 1])
                .font(.subheadline.weight(.bold))
                .foregroundStyle(selected ? .white : .limorInk)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.limorIndigo : Color.limorMuted.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

    private func quickPick(label: String, target: Set<Int>) -> some View {
        Button {
            days = target
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorIndigo)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private var previewLine: some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeText = formatter.string(from: time)
        return HStack(spacing: 6) {
            Image(systemName: "bell.badge").font(.caption)
            Text("תקבל התראה ב-\(timeText), \(weekdayList(days))")
                .font(.caption)
        }
        .foregroundStyle(.limorIndigo)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = initial {
            existing.task = trimmedTask
            existing.daysOfWeek = days
            existing.hour = comps.hour ?? 7
            existing.minute = comps.minute ?? 45
            onSave(existing)
        } else {
            let reminder = RecurringReminder(
                task: trimmedTask,
                daysOfWeek: days,
                hour: comps.hour ?? 7,
                minute: comps.minute ?? 45
            )
            onSave(reminder)
        }
        dismiss()
    }
}
